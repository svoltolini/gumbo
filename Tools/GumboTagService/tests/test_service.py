# SPDX-License-Identifier: GPL-2.0-or-later
import copy
import http.client
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from engine import FileEngine, ServiceError, Cancelled, load_audio, media_signature, unrelated_tags, validate_request
from server import JobStore, HTTPServer

FIXTURES = Path(__file__).parent / "fixtures"


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.music = self.base / "music"
        self.music.mkdir()
        for fixture in FIXTURES.glob("tone.*"):
            shutil.copyfile(fixture, self.music / fixture.name)
        self.engine = FileEngine(self.music)

    def tearDown(self):
        self.engine.close()
        self.temporary.cleanup()

    def edit(self, name="tone.mp3"):
        value = self.engine.inspect(name)
        return {"path": name, "expected": value["expected"], "changes": {"album": "A new album", "albumArtist": "Several Artists", "genre": "Jazz"}}

    def execute(self, entry, **options):
        return self.engine.execute(entry, str(uuid.uuid4()), 0, lambda: False, lambda outcome: None, **options)

    def test_all_formats_preserve_audio_unrelated_tags_and_permissions(self):
        for extension in ("mp3", "flac", "m4a"):
            with self.subTest(extension=extension):
                path = self.music / ("tone." + extension)
                path.chmod(0o640)
                edit = self.edit(path.name)
                with path.open("rb") as source:
                    audio = load_audio(source, path.name)
                    media = media_signature(source, audio, edit["changes"], lambda: False)
                    tags = unrelated_tags(audio, edit["changes"])
                result = self.execute(edit)
                self.assertEqual(result["status"], "succeeded")
                self.assertNotEqual(result["before"]["sha256"], result["after"]["sha256"])
                inspected = self.engine.inspect(path.name)
                self.assertEqual(result["after"], {**inspected["expected"], "fields": inspected["fields"]})
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                with path.open("rb") as source:
                    audio = load_audio(source, path.name)
                    self.assertEqual(media, media_signature(source, audio, edit["changes"], lambda: False))
                    self.assertEqual(tags, unrelated_tags(audio, edit["changes"]))
                self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_dry_run_validates_without_changing_original(self):
        path = self.music / "tone.flac"
        before = path.read_bytes()
        result = self.execute(self.edit(path.name), dry_run=True)
        self.assertEqual(result["status"], "validated")
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_traversal_symlink_hardlink_and_non_audio_paths_rejected(self):
        (self.music / "linked.mp3").symlink_to(self.music / "tone.mp3")
        (self.music / "outside").symlink_to(self.base, target_is_directory=True)
        os.link(self.music / "tone.flac", self.music / "hard.flac")
        for path in ("../tone.mp3", "/tone.mp3", "a/../tone.mp3", "a//tone.mp3", "a\\tone.mp3", "linked.mp3", "outside/music/tone.mp3", "hard.flac", ".gumbo-tag-hidden.mp3", "password.txt"):
            with self.subTest(path=path), self.assertRaises(ServiceError):
                self.engine.inspect(path)

    def test_conflict_before_edit_and_immediately_before_replace(self):
        path = self.music / "tone.mp3"
        edit = self.edit()
        path.write_bytes(path.read_bytes() + b"changed")
        changed = path.read_bytes()
        with self.assertRaisesRegex(ServiceError, "changed"):
            self.execute(edit)
        self.assertEqual(path.read_bytes(), changed)
        shutil.copyfile(FIXTURES / path.name, path)
        edit = self.edit()
        def modify():
            path.write_bytes(path.read_bytes() + b"another writer")
        with self.assertRaisesRegex(ServiceError, "changed"):
            self.execute(edit, before_commit=modify)
        self.assertTrue(path.read_bytes().endswith(b"another writer"))
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_corrupt_audio_and_low_disk_space_never_replace_original(self):
        path = self.music / "tone.mp3"
        path.write_bytes(b"not audio")
        with self.assertRaises(ServiceError):
            self.execute(self.edit())
        self.assertEqual(path.read_bytes(), b"not audio")
        shutil.copyfile(FIXTURES / path.name, path)
        class EmptyDisk:
            f_bavail = 0
            f_frsize = 4096
        with patch("engine.os.fstatvfs", return_value=EmptyDisk()), self.assertRaisesRegex(ServiceError, "room"):
            self.execute(self.edit())
        self.assertEqual(path.read_bytes(), (FIXTURES / path.name).read_bytes())

    def test_rollback_restores_original_when_post_replace_verification_fails(self):
        path = self.music / "tone.m4a"
        before = path.read_bytes()
        def fail():
            raise ServiceError("test_failure", "Verification failed")
        with self.assertRaises(ServiceError):
            self.execute(self.edit(path.name), after_replace=fail)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_cancellation_before_commit_keeps_original(self):
        path = self.music / "tone.flac"
        before = path.read_bytes()
        stopped = False
        def cancel():
            nonlocal stopped
            stopped = True
        with self.assertRaises(Cancelled):
            self.engine.execute(self.edit(path.name), str(uuid.uuid4()), 0, lambda: stopped, lambda result: None, before_commit=cancel)
        self.assertEqual(path.read_bytes(), before)

    def test_lost_durable_ack_retains_recovery_copy_and_never_claims_failure_before_write(self):
        path = self.music / "tone.mp3"
        before = path.read_bytes()
        def fail(_):
            raise OSError("simulated state volume failure")
        with self.assertRaises(ServiceError) as raised:
            self.engine.execute(self.edit(), str(uuid.uuid4()), 0, lambda: False, fail)
        self.assertEqual(raised.exception.code, "recovery_required")
        self.assertNotEqual(path.read_bytes(), before)
        backups = list(self.music.glob("*.backup"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)

    def test_job_replay_restart_and_conflicting_identifier(self):
        identifier = str(uuid.uuid4())
        request = {"version": 1, "files": [self.edit()]}
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        _, created = store.submit(identifier, request)
        self.assertTrue(created)
        store.run_job(identifier)
        self.assertEqual(store.status(identifier)["status"], "completed")
        after = (self.music / "tone.mp3").read_bytes()
        outcome, created = store.submit(identifier, request)
        self.assertFalse(created)
        self.assertEqual(outcome["files"][0]["status"], "succeeded")
        altered = copy.deepcopy(request)
        altered["files"][0]["changes"]["genre"] = "Rock"
        with self.assertRaisesRegex(ServiceError, "different edits"):
            store.submit(identifier, altered)
        store.close()
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        self.assertFalse(store.submit(identifier, request)[1])
        self.assertEqual((self.music / "tone.mp3").read_bytes(), after)
        store.close()

    def test_partial_job_and_cancel_between_files_reports_confirmed_outcomes(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        identifier = str(uuid.uuid4())
        request = {"version": 1, "files": [self.edit(), self.edit("tone.flac")]}
        store.submit(identifier, request)
        original_execute = self.engine.execute
        def execute(*args, **kwargs):
            result = original_execute(*args, **kwargs)
            store.cancel(identifier)
            return result
        with patch.object(self.engine, "execute", side_effect=execute):
            store.run_job(identifier)
        self.assertEqual([item["status"] for item in store.status(identifier)["files"]], ["succeeded", "cancelled"])
        self.assertEqual((self.music / "tone.flac").read_bytes(), (FIXTURES / "tone.flac").read_bytes())
        store.close()

    def test_restart_marks_running_file_unconfirmed_and_never_reexecutes(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        identifier = str(uuid.uuid4())
        request = {"version": 1, "files": [self.edit(), self.edit("tone.flac")]}
        result, _ = store.submit(identifier, request)
        result["status"] = "running"
        result["files"][0]["status"] = "running"
        store._save(identifier, result)
        store.close()
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        replay, created = store.submit(identifier, request)
        self.assertFalse(created)
        self.assertEqual(replay["status"], "interrupted")
        self.assertEqual([item["status"] for item in replay["files"]], ["unconfirmed", "cancelled"])
        store.close()

    def test_authentication_and_http_contract(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        server = HTTPServer(("127.0.0.1", 0), self.engine, store, "t" * 43)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            def request(method, route, body=None, token=None):
                connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                headers = {"Content-Type": "application/json"}
                if token:
                    headers["Authorization"] = "Bearer " + token
                connection.request(method, route, json.dumps(body).encode() if body is not None else None, headers)
                response = connection.getresponse()
                data = json.loads(response.read())
                connection.close()
                return response.status, data
            self.assertEqual(request("GET", "/v1/capabilities")[0], 401)
            self.assertEqual(request("POST", "/v1/files/stat", {"path": "tone.mp3"}, "wrong")[0], 401)
            code, result = request("GET", "/v1/capabilities", token="t" * 43)
            self.assertEqual((code, result["version"]), (200, 1))
            self.assertEqual(request("POST", "/v1/files/stat", {"path": "../private.mp3"}, "t" * 43)[0], 400)
            self.assertEqual(request("POST", "/v1/files/stat", {"path": "tone.mp3"}, "t" * 43)[0], 200)
            identifier = str(uuid.uuid4())
            self.assertEqual(request("PUT", "/v1/jobs/" + identifier, {"version": 1, "files": [self.edit()]}, "t" * 43)[0], 202)
            self.assertEqual(request("POST", "/v1/jobs/" + identifier + "/cancel", {}, "t" * 43)[0], 200)
            store.run_job(identifier)
            self.assertEqual(store.status(identifier)["files"][0]["status"], "cancelled")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            store.close()

    def test_unknown_fields_and_invalid_expectations_rejected(self):
        request = {"version": 1, "files": [self.edit()]}
        for field, value in (("version", True), ("version", 2), ("dryRun", "yes"), ("command", "delete")):
            with self.subTest(field=field, value=value), self.assertRaises(ServiceError):
                validate_request({**request, field: value})
        request["files"][0]["changes"] = {"path": "elsewhere"}
        with self.assertRaises(ServiceError):
            validate_request(request)

    def test_only_missing_genre_reads_file_tags_and_returns_unchanged_fields(self):
        for name in ("tone.mp3", "tone.flac", "tone.m4a"):
            with self.subTest(name=name):
                self.execute(self.edit(name))
                before = (self.music / name).read_bytes()
                edit = self.edit(name)
                edit.update(changes={"genre": "Rock"}, onlyIfGenreMissing=True)
                result = self.execute(edit)
                self.assertEqual(result["status"], "unchanged")
                self.assertEqual(result["after"]["fields"]["genre"], "Jazz")
                self.assertEqual((self.music / name).read_bytes(), before)
                edit["onlyIfGenreMissing"] = False
                result = self.execute(edit)
                self.assertEqual(result["status"], "succeeded")
                self.assertEqual(result["after"]["fields"]["genre"], "Rock")


if __name__ == "__main__":
    unittest.main()
