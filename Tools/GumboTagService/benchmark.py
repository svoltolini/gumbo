# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare actual helper JSON traffic with a whole-file download/edit/upload fixture.

No NAS address is accepted. Every file is generated in a temporary directory, and both
servers bind to 127.0.0.1. This measures transport costs, not the Apple app's UI or DSM.
Requires the helper requirements plus imageio-ffmpeg==0.6.0 as a development-only tool.
"""
import argparse
import http.client
import json
import os
import platform
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import imageio_ffmpeg
import mutagen
from engine import FileEngine, load_audio, media_signature, unrelated_tags
from server import HTTPServer, JobStore


CHANGES = {"genre": "Jazz"}


class Traffic:
    def __init__(self, port, token=None):
        self.port, self.token = port, token
        self.request_bytes = self.response_bytes = self.requests = 0

    def request(self, method, path, body=None, json_body=None):
        headers = {}
        if json_body is not None:
            body = json.dumps(json_body, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        body = body or b""
        self.requests += 1
        self.request_bytes += len(body)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=120)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            result = response.read()
            self.response_bytes += len(result)
            if response.status not in (200, 201, 202, 204):
                raise RuntimeError("Fixture request failed: " + str(response.status) + " " + result.decode(errors="replace"))
            return json.loads(result) if json_body is not None or path.startswith("/v1/") else result
        finally:
            connection.close()

    def metrics(self, seconds):
        return {"seconds": round(seconds, 6), "requests": self.requests,
                "request_body_bytes": self.request_bytes, "response_body_bytes": self.response_bytes,
                "total_body_bytes": self.request_bytes + self.response_bytes}


class FileFixtureHandler(BaseHTTPRequestHandler):
    """Deliberately small reference transport, restricted to pre-generated known filenames."""
    def log_message(self, *_):
        pass

    def do_GET(self):
        name = self.path.removeprefix("/")
        if name not in self.server.names:
            self.send_error(404)
            return
        data = (self.server.root / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        name = self.path.removeprefix("/")
        length = int(self.headers.get("Content-Length", "-1"))
        if name not in self.server.names or not 0 < length <= 256 * 1024 * 1024:
            self.send_error(400)
            return
        data = self.rfile.read(length)
        if len(data) != length:
            self.send_error(400)
            return
        stage = self.server.root / (".stage-" + uuid.uuid4().hex)
        stage.write_bytes(data)
        os.replace(stage, self.server.root / name)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


def signature(path):
    with path.open("rb") as stream:
        audio = load_audio(stream, path.name)
        return media_signature(stream, audio, CHANGES, lambda: False), unrelated_tags(audio, CHANGES)


def generate(directory, seconds, copies):
    executable = imageio_ffmpeg.get_ffmpeg_exe()
    names = []
    for extension, codec in (("mp3", "libmp3lame"), ("flac", "flac"), ("m4a", "aac")):
        destination = directory / ("template." + extension)
        command = [executable, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                   "anoisesrc=color=pink:sample_rate=44100:amplitude=0.01:duration=" + str(seconds) + ":seed=1729",
                   "-ac", "2", "-c:a", codec, "-metadata", "title=Generated test audio",
                   "-metadata", "artist=Gumbo fixture", "-metadata", "album=Generated benchmark album",
                   "-metadata", "comment=Preserve this unrelated tag"]
        if extension != "flac":
            command += ["-b:a", "192k"]
        subprocess.run(command + [str(destination)], check=True, capture_output=True)
        for index in range(copies):
            name = str(index + 1).zfill(2) + "-generated." + extension
            shutil.copy2(destination, directory / name)
            names.append(name)
        destination.unlink()
    version = subprocess.run([executable, "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0]
    return names, version


def run(seconds, copies, repetitions):
    with tempfile.TemporaryDirectory(prefix="gumbo-helper-benchmark-") as temporary:
        root = Path(temporary)
        original = root / "original"
        original.mkdir()
        names, ffmpeg = generate(original, seconds, copies)
        signatures = {name: signature(original / name) for name in names}
        result = {"python": platform.python_version(), "platform": platform.platform(), "mutagen": mutagen.version_string,
                  "ffmpeg": ffmpeg, "files": len(names), "seconds_per_file": seconds,
                  "original_bytes": sum((original / name).stat().st_size for name in names),
                  "bytes_by_format": {ext: sum((original / name).stat().st_size for name in names if name.endswith("." + ext)) for ext in ("mp3", "flac", "m4a")},
                  "scope": "loopback HTTP, generated audio, temporary local disk; body bytes exclude headers/TLS; not DSM or Apple UI", "runs": []}
        for iteration in range(repetitions):
            helper_root, baseline_root, client_root = (root / (kind + str(iteration)) for kind in ("helper", "baseline", "client"))
            shutil.copytree(original, helper_root)
            shutil.copytree(original, baseline_root)
            client_root.mkdir()
            helper_engine = FileEngine(helper_root)
            jobs = JobStore(root / ("state" + str(iteration)), helper_engine)
            token = secrets.token_urlsafe(32)
            helper = HTTPServer(("127.0.0.1", 0), helper_engine, jobs, token)
            baseline = ThreadingHTTPServer(("127.0.0.1", 0), FileFixtureHandler)
            baseline.root, baseline.names = baseline_root, set(names)
            threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (helper, baseline)]
            for thread in threads:
                thread.start()
            try:
                helper_traffic = Traffic(helper.server_port, token)
                start = time.perf_counter()
                helper_traffic.request("GET", "/v1/capabilities")
                for name in names:
                    inspected = helper_traffic.request("POST", "/v1/files/stat", json_body={"path": name})
                    path = "/v1/jobs/" + str(uuid.uuid4())
                    outcome = helper_traffic.request("PUT", path, json_body={"version": 1, "files": [{"path": name, "expected": inspected["expected"], "changes": CHANGES, "onlyIfGenreMissing": True}]})
                    while outcome["status"] in ("queued", "running"):
                        time.sleep(0.01)
                        outcome = helper_traffic.request("GET", path)
                    assert outcome["status"] == "completed" and outcome["files"][0]["status"] == "succeeded", outcome
                helper_metrics = helper_traffic.metrics(time.perf_counter() - start)

                baseline_traffic = Traffic(baseline.server_port)
                client_engine = FileEngine(client_root)
                try:
                    start = time.perf_counter()
                    for name in names:
                        local = client_root / name
                        local.write_bytes(baseline_traffic.request("GET", "/" + name))
                        inspected = client_engine.inspect(name)
                        entry = {"path": name, "expected": inspected["expected"], "changes": CHANGES, "onlyIfGenreMissing": True}
                        outcome = client_engine.execute(entry, str(uuid.uuid4()), 0, lambda: False, lambda _: None)
                        assert outcome["status"] == "succeeded", outcome
                        baseline_traffic.request("PUT", "/" + name, body=local.read_bytes())
                        local.unlink()
                    baseline_metrics = baseline_traffic.metrics(time.perf_counter() - start)
                finally:
                    client_engine.close()
                # Both routes must actually edit every file and retain identical audio/unrelated tags.
                for server_root in (helper_root, baseline_root):
                    verification = FileEngine(server_root)
                    try:
                        for name in names:
                            assert verification.inspect(name)["fields"]["genre"] == "Jazz"
                            assert signature(server_root / name) == signatures[name]
                    finally:
                        verification.close()
                result["runs"].append({"helper": helper_metrics, "whole_file_reference": baseline_metrics,
                    "audio_and_unrelated_tags_verified": True,
                    "body_byte_reduction_percent": round(100 * (1 - helper_metrics["total_body_bytes"] / baseline_metrics["total_body_bytes"]), 4)})
            finally:
                for server in (helper, baseline):
                    server.shutdown()
                    server.server_close()
                for thread in threads:
                    thread.join(timeout=2)
                jobs.close()
                helper_engine.close()
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--copies-per-format", type=int, default=4)
    parser.add_argument("--repetitions", type=int, default=3)
    options = parser.parse_args()
    if not 1 <= options.seconds <= 300 or not 1 <= options.copies_per_format <= 12 or not 1 <= options.repetitions <= 10:
        parser.error("Keep generated duration 1–300 seconds, copies 1–12, repetitions 1–10.")
    run(options.seconds, options.copies_per_format, options.repetitions)
