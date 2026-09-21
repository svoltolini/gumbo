#!/usr/bin/env python3
"""Qualify mutation semantics on disposable local WsgiDAV files, never a user's NAS.

This is a server-behavior experiment, not an app transport/authentication test.
All servers bind to loopback; every modified file is generated in TemporaryDirectory.
"""
import errno
import http.client
import json
import os
import platform
import tempfile
import threading
from pathlib import Path
from unittest.mock import patch
from wsgiref.simple_server import make_server, WSGIRequestHandler

import wsgidav
from wsgidav.wsgidav_app import WsgiDAVApp
from wsgidav.dav_error import DAVError, HTTP_INTERNAL_ERROR
from wsgidav.fs_dav_provider import FileResource


class QuietRequestHandler(WSGIRequestHandler):
    def log_message(self, *_):
        pass


def run():
    with tempfile.TemporaryDirectory(prefix="gumbo-dav-write-") as temporary:
        root = Path(temporary)
        app = WsgiDAVApp({
            "provider_mapping": {"/": str(root)},
            "simple_dc": {"user_mapping": {"*": True}},
            "verbose": 0,
            "logging": {"enable": False},
        })
        server = make_server("127.0.0.1", 0, app, handler_class=QuietRequestHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_port)

        def request(method, path, body=None, headers=None):
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            try:
                connection.request(method, path, body=body, headers=headers or {})
                response = connection.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                connection.close()

        def etag(path):
            status, headers, _ = request("GET", path)
            assert status == 200
            return next(value for key, value in headers.items() if key.lower() == "etag")

        def write(name, byte):
            (root / name).write_bytes(bytes([byte]) * 4096)

        def tagged_move(source, destination, destination_etag):
            return request("MOVE", source, headers={
                "Destination": base + destination,
                "Overwrite": "T",
                "If": "<" + base + destination + "> ([" + destination_etag + "])",
            })

        result = {"server": "WsgiDAV " + wsgidav.__version__, "python": platform.python_version(),
                  "platform": platform.platform(), "scope": "temporary generated files; loopback HTTP; no NAS"}
        try:
            status, headers, _ = request("OPTIONS", "/")
            result["options"] = {"status": status, "dav": headers.get("DAV"), "allow": headers.get("Allow")}
            write("delete.bin", 65)
            status, _, _ = request("DELETE", "/delete.bin", headers={"If-Match": '"wrong-version"'})
            result["stale_delete"] = {"status": status, "original_preserved": (root / "delete.bin").read_bytes() == b"A" * 4096}
            assert status == 412 and result["stale_delete"]["original_preserved"]

            write("stage.bin", 66)
            write("target.bin", 65)
            status, _, _ = tagged_move("/stage.bin", "/target.bin", '"wrong-version"')
            result["stale_destination_move"] = {"status": status, "original_preserved": (root / "target.bin").read_bytes() == b"A" * 4096}

            # A local NAS writer can rewrite equal-length content while restoring its timestamp.
            # Such files must not qualify as strongly versioned simply because the ETag has quotes.
            before = etag("/target.bin")
            stat = (root / "target.bin").stat()
            write("target.bin", 67)
            os.utime(root / "target.bin", ns=(stat.st_atime_ns, stat.st_mtime_ns))
            after = etag("/target.bin")
            result["external_same_stat_rewrite"] = {"etag_changed": before != after, "bytes_changed": True}

            # Inject failure exactly where the real filesystem provider executes the final move.
            # A staged upload must not destroy the destination if final replacement fails.
            write("stage.bin", 66)
            write("target.bin", 65)
            current = etag("/target.bin")
            with patch.object(FileResource, "move_recursive", side_effect=DAVError(HTTP_INTERNAL_ERROR, OSError(errno.ENOSPC, "fixture disk full"))) as final_move:
                status, _, _ = tagged_move("/stage.bin", "/target.bin", current)
            result["final_move_failure"] = {"status": status, "original_exists": (root / "target.bin").exists(),
                                            "staging_exists": (root / "stage.bin").exists(), "failure_point_reached": final_move.called}
            assert final_move.called and status >= 500

            # Model another NAS writer replacing the reviewed file after HTTP condition checking.
            write("delete.bin", 65)
            reviewed = etag("/delete.bin")
            original_delete = FileResource.delete
            def concurrent_delete(resource):
                if resource.path == "/delete.bin":
                    write("replacement.bin", 68)
                    os.replace(root / "replacement.bin", root / "delete.bin")
                return original_delete(resource)
            with patch.object(FileResource, "delete", concurrent_delete):
                status, _, _ = request("DELETE", "/delete.bin", headers={"If-Match": reviewed})
            result["external_replacement_before_unlink"] = {"status": status, "replacement_preserved": (root / "delete.bin").exists()}
            result["qualifies_for_generic_reviewed_mutations"] = all((
                result["stale_destination_move"]["original_preserved"],
                result["external_same_stat_rewrite"]["etag_changed"],
                result["final_move_failure"]["original_exists"],
                result["external_replacement_before_unlink"]["replacement_preserved"],
            ))
            print(json.dumps(result, indent=2))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    run()
