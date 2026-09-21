# SPDX-License-Identifier: GPL-2.0-or-later
"""Authenticated, versioned JSON API. No NAS discovery, internet metadata or shell execution."""
import argparse
import contextlib
import hashlib
import hmac
import json
import os
import queue
import signal
import socket
import sqlite3
import ssl
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from engine import Cancelled, FileEngine, ServiceError, validate_request, MAX_FILES, MAX_FILE_BYTES

MAX_BODY = 256 * 1024


def job_identifier(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ServiceError("invalid_job", "Use a canonical UUID job identifier.") from error
    if str(parsed) != value:
        raise ServiceError("invalid_job", "Use a lowercase canonical UUID job identifier.")
    return value


class JobStore:
    """One serialized writer; job IDs remain durable across restarts and response loss."""
    def __init__(self, state_directory, engine, start_worker=True):
        state = Path(state_directory).absolute()
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        if state.is_symlink() or os.path.commonpath([str(state.resolve()), engine.root]) in (str(state.resolve()), engine.root):
            raise ValueError("The private state directory must be separate from the music root.")
        os.chmod(state, 0o700)
        self.engine = engine
        self.lock = threading.RLock()
        self.database = sqlite3.connect(str(state / "jobs.sqlite3"), check_same_thread=False)
        self.database.execute("PRAGMA journal_mode=WAL")
        self.database.execute("PRAGMA synchronous=FULL")
        self.database.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, digest TEXT NOT NULL, request TEXT NOT NULL, result TEXT NOT NULL, cancelled INTEGER NOT NULL DEFAULT 0)")
        self.database.commit()
        self.queue = queue.Queue(maxsize=8)
        self.stopping = threading.Event()
        self.worker = None
        # Never replay an interrupted write: replacement may have happened before acknowledgement.
        for identifier, result in self.database.execute("SELECT id,result FROM jobs WHERE json_extract(result, '$.status') IN ('queued','running')").fetchall():
            result = json.loads(result)
            if result["status"] not in ("queued", "running"):
                continue
            for entry in result["files"]:
                if entry["status"] == "running":
                    entry.update(status="unconfirmed", error={"code": "interrupted", "message": "The service stopped during this file. Inspect the file and recovery copy before retrying."})
                elif entry["status"] == "pending":
                    entry["status"] = "cancelled"
            result["status"] = "interrupted"
            self._save(identifier, result)
        if start_worker:
            self.worker = threading.Thread(target=self._run, name="tag-writer", daemon=True)
            self.worker.start()

    def _save(self, identifier, result):
        with self.lock:
            self.database.execute("UPDATE jobs SET result=? WHERE id=?", (json.dumps(result), identifier))
            self.database.commit()

    def submit(self, identifier, request):
        job_identifier(identifier)
        validate_request(request)
        if request.get("operation") == "delete" and not self.engine.allow_deletion:
            raise ServiceError("deletion_disabled", "Reviewed deletion is not enabled by this server's owner.", 403)
        encoded = json.dumps(request, sort_keys=True, separators=(",", ":"))
        request_digest = hashlib.sha256(encoded.encode()).hexdigest()
        with self.lock:
            existing = self.database.execute("SELECT digest,result FROM jobs WHERE id=?", (identifier,)).fetchone()
            if existing:
                if existing[0] != request_digest:
                    raise ServiceError("job_conflict", "That job identifier was already used for different edits.", 409)
                return json.loads(existing[1]), False
            if self.stopping.is_set() or self.queue.full():
                raise ServiceError("busy", "The helper's edit queue is full. Try later.", 503)
            result = {"version": 1, "jobID": identifier, "status": "queued", "dryRun": request.get("dryRun", False),
                      "operation": request.get("operation", "tags"),
                      "files": [{"path": entry["path"], "status": "pending"} for entry in request["files"]]}
            self.database.execute("INSERT INTO jobs(id,digest,request,result) VALUES(?,?,?,?)", (identifier, request_digest, encoded, json.dumps(result)))
            self.database.commit()
            self.queue.put_nowait(identifier)
            return result, True

    def status(self, identifier):
        job_identifier(identifier)
        with self.lock:
            row = self.database.execute("SELECT result FROM jobs WHERE id=?", (identifier,)).fetchone()
        if not row:
            raise ServiceError("job_not_found", "No such job exists.", 404)
        return json.loads(row[0])

    def cancel(self, identifier):
        self.status(identifier)
        with self.lock:
            self.database.execute("UPDATE jobs SET cancelled=1 WHERE id=?", (identifier,))
            self.database.commit()
        return self.status(identifier)

    def _cancelled(self, identifier):
        with self.lock:
            row = self.database.execute("SELECT cancelled FROM jobs WHERE id=?", (identifier,)).fetchone()
        return self.stopping.is_set() or not row or bool(row[0])

    def _run(self):
        while not self.stopping.is_set():
            try:
                identifier = self.queue.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                self.run_job(identifier)
            except Exception:
                # A broken state volume must stop acceptance, not leave a silently dead worker.
                self.stopping.set()
            finally:
                self.queue.task_done()

    def run_job(self, identifier):
        with self.lock:
            row = self.database.execute("SELECT request,result FROM jobs WHERE id=?", (identifier,)).fetchone()
        request, result = json.loads(row[0]), json.loads(row[1])
        if result["status"] != "queued":
            return
        result["status"] = "running"
        self._save(identifier, result)
        for index, entry in enumerate(request["files"]):
            if self._cancelled(identifier):
                result["files"][index]["status"] = "cancelled"
                continue
            result["files"][index]["status"] = "running"
            self._save(identifier, result)

            def persist_success(outcome):
                result["files"][index] = outcome
                self._save(identifier, result)

            try:
                execute = self.engine.delete if request.get("operation") == "delete" else self.engine.execute
                execute(entry, identifier, index, lambda: self._cancelled(identifier), persist_success,
                                    dry_run=request.get("dryRun", False))
            except ServiceError as error:
                result["files"][index] = {"path": entry["path"], "status": "cancelled" if isinstance(error, Cancelled) else "unconfirmed" if error.code == "recovery_required" else "failed",
                                          "error": {"code": error.code, "message": error.message}}
            except Exception:
                # Don't expose host paths, stack traces or token/configuration details over HTTP.
                result["files"][index] = {"path": entry["path"], "status": "failed",
                                          "error": {"code": "operation_failed", "message": "The edit could not be completed. Inspect the file before retrying."}}
            self._save(identifier, result)
            if result["files"][index]["status"] == "unconfirmed":
                for remaining in result["files"][index + 1:]:
                    remaining["status"] = "cancelled"
                break
        statuses = {entry["status"] for entry in result["files"]}
        complete = {"succeeded", "unchanged", "validated", "deleted"}
        result["status"] = "completed" if statuses <= complete else "cancelled" if statuses <= complete | {"cancelled"} else "partial"
        self._save(identifier, result)

    def close(self):
        self.stopping.set()
        if self.worker:
            # Cancellation checkpoints bound most work to one chunk; allow the current atomic commit to finish.
            self.worker.join(timeout=30)
            if self.worker.is_alive():
                return
        self.database.close()


class HTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, engine, jobs, token):
        self.engine, self.jobs, self.token = engine, jobs, token
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        # Never emit request contents or bearer tokens through default traceback logging.
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "GumboTagService/1"
    sys_version = ""
    protocol_version = "HTTP/1.0"  # One bounded request per connection, no request smuggling/keepalive state.

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, format, *args):
        pass

    def respond(self, status, value):
        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        if self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) != 1:
            raise ServiceError("invalid_body", "A single Content-Length is required.")
        try:
            length = int(self.headers["Content-Length"])
        except ValueError as error:
            raise ServiceError("invalid_body", "Invalid Content-Length.") from error
        if not 0 < length <= MAX_BODY:
            raise ServiceError("invalid_body", "The request body is too large or empty.", 413)
        if self.headers.get_content_type() != "application/json":
            raise ServiceError("invalid_body", "Use application/json.", 415)
        data = self.rfile.read(length)
        if len(data) != length:
            raise ServiceError("invalid_body", "The request body was incomplete.")
        try:
            return json.loads(data)
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ServiceError("invalid_body", "Invalid JSON.") from error

    def handle_api(self):
        try:
            authorizations = self.headers.get_all("Authorization", [])
            if len(authorizations) != 1 or not hmac.compare_digest(authorizations[0].encode(), ("Bearer " + self.server.token).encode()):
                raise ServiceError("unauthorized", "A valid helper token is required.", 401)
            if "?" in self.path or "%" in self.path or "#" in self.path:
                raise ServiceError("not_found", "Unknown endpoint.", 404)
            if self.command == "GET" and self.path == "/v1/capabilities":
                self.respond(200, {"version": 1, "service": "GumboTagService", "fields": ["album", "albumArtist", "genre"],
                                   "formats": ["mp3", "flac", "m4a"], "maxFiles": MAX_FILES, "maxFileBytes": MAX_FILE_BYTES,
                                   "requiresSHA256": True, "supportsDryRun": True,
                                   "supportsReviewedDeletion": self.server.engine.allow_deletion,
                                   "supportsVerifiedInspection": self.server.engine.allow_deletion})
                return
            if self.command == "POST" and self.path == "/v1/files/stat":
                value = self.body()
                if not isinstance(value, dict) or set(value) != {"path"}:
                    raise ServiceError("invalid_request", "Only path is accepted.")
                self.respond(200, {"version": 1, **self.server.engine.inspect(value["path"])})
                return
            if self.command == "POST" and self.path == "/v1/files/review-delete":
                value = self.body()
                if not isinstance(value, dict) or set(value) != {"path"}:
                    raise ServiceError("invalid_request", "Only path is accepted.")
                self.respond(200, {"version": 1, **self.server.engine.review_deletion(value["path"])})
                return
            if self.command == "POST" and self.path == "/v1/files/inspect-range":
                self.respond(200, {"version": 1, **self.server.engine.inspection_read(self.body())})
                return
            parts = self.path.split("/")
            if len(parts) in (4, 5) and parts[1:3] == ["v1", "jobs"]:
                identifier = job_identifier(parts[3])
                if len(parts) == 4 and self.command == "PUT":
                    result, created = self.server.jobs.submit(identifier, self.body())
                    self.respond(202 if created else 200, result)
                    return
                if len(parts) == 4 and self.command == "GET":
                    self.respond(200, self.server.jobs.status(identifier))
                    return
                if len(parts) == 5 and parts[4] == "cancel" and self.command == "POST":
                    if self.body() != {}:
                        raise ServiceError("invalid_request", "The cancel body must be an empty JSON object.")
                    self.respond(200, self.server.jobs.cancel(identifier))
                    return
            raise ServiceError("not_found", "Unknown endpoint.", 404)
        except ServiceError as error:
            self.respond(error.status, {"version": 1, "error": {"code": error.code, "message": error.message}})
        except (OSError, ValueError, sqlite3.Error):
            self.respond(500, {"version": 1, "error": {"code": "service_error", "message": "The helper could not complete the request."}})

    do_GET = handle_api
    do_POST = handle_api
    do_PUT = handle_api


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--music-root", default=os.environ.get("GUMBO_MUSIC_ROOT", "/music"))
    parser.add_argument("--state-directory", default=os.environ.get("GUMBO_STATE_DIRECTORY", "/state"))
    parser.add_argument("--token-file", default=os.environ.get("GUMBO_TOKEN_FILE", "/run/secrets/token"))
    parser.add_argument("--certificate", default=os.environ.get("GUMBO_TLS_CERT", "/run/secrets/cert.pem"))
    parser.add_argument("--private-key", default=os.environ.get("GUMBO_TLS_KEY", "/run/secrets/key.pem"))
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--http-loopback", action="store_true", help="Development only: forces 127.0.0.1 and disables TLS")
    parser.add_argument("--allow-reviewed-deletion", action="store_true", default=os.environ.get("GUMBO_ALLOW_DELETION") == "1",
                        help="Allow authenticated, reviewed exact-file deletion; disabled by default")
    options = parser.parse_args()
    token = Path(options.token_file).read_text().strip()
    if len(token) < 43 or len(token) > 256 or any(not (char.isascii() and (char.isalnum() or char in "_-")) for char in token):
        raise ValueError("Use a token generated from at least 32 random bytes in URL-safe base64.")
    engine = FileEngine(options.music_root, allow_deletion=options.allow_reviewed_deletion)
    jobs = JobStore(options.state_directory, engine)
    server = HTTPServer(("127.0.0.1" if options.http_loopback else options.bind, options.port), engine, jobs, token)
    if not options.http_loopback:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(options.certificate, options.private_key)
        # Negotiate inside the bounded request thread, where the socket timeout applies.
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)

    def shutdown(*_):
        jobs.stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        jobs.close()
        engine.close()


if __name__ == "__main__":
    main()
