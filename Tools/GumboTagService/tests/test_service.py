# SPDX-License-Identifier: GPL-2.0-or-later
import base64
import contextlib
import copy
import errno
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from engine import FileEngine, ServiceError, Cancelled, load_audio, media_signature, storage_error, unrelated_tags, validate_request
from server import JobStore, HTTPServer, MAX_ACTIVE_REQUESTS, MAX_CONNECTIONS_PER_ADDRESS

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

    @unittest.skipUnless(sys.platform == "linux", "Checks the deployed Linux filesystem behavior")
    def test_linux_extended_attributes_and_identity_survive_replacement(self):
        for extension in ("mp3", "flac", "m4a"):
            with self.subTest(extension=extension):
                path = self.music / ("tone." + extension)
                os.setxattr(path, "user.gumbo.fixture", b"preserve exact metadata")
                before = path.stat()
                self.assertEqual(self.execute(self.edit(path.name))["status"], "succeeded")
                self.assertEqual(os.getxattr(path, "user.gumbo.fixture"), b"preserve exact metadata")
                self.assertEqual((path.stat().st_uid, path.stat().st_gid), (before.st_uid, before.st_gid))

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("setfacl") and shutil.which("getfacl"),
                         "Linux validation image supplies POSIX ACL tools")
    def test_linux_named_user_acl_survives_replacement(self):
        path = self.music / "tone.flac"
        subprocess.run(["setfacl", "-m", "u:12345:r--", str(path)], check=True)
        before = subprocess.check_output(["getfacl", "-c", "-p", "-n", str(path)])
        self.assertEqual(self.execute(self.edit(path.name))["status"], "succeeded")
        after = subprocess.check_output(["getfacl", "-c", "-p", "-n", str(path)])
        self.assertEqual(after, before)

    @unittest.skipIf(os.geteuid() == 0, "Requires the production non-root execution model")
    def test_unwritable_parent_keeps_original_and_leaves_no_recovery_files(self):
        path = self.music / "tone.mp3"
        edit = self.edit(path.name)
        before = path.read_bytes()
        self.music.chmod(0o500)
        try:
            with self.assertRaises(ServiceError):
                self.execute(edit)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])
        finally:
            self.music.chmod(0o700)

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
            self.assertFalse(result["supportsReviewedDeletion"])
            self.assertEqual(request("POST", "/v1/files/review-delete", {"path": "tone.mp3"}, "t" * 43)[0], 403)
            self.engine.allow_deletion = True
            self.assertTrue(request("GET", "/v1/capabilities", token="t" * 43)[1]["supportsReviewedDeletion"])
            code, reviewed = request("POST", "/v1/files/review-delete", {"path": "tone.mp3"}, "t" * 43)
            self.assertEqual(code, 200)
            code, inspected = request("POST", "/v1/files/inspect-range", {"path": "tone.mp3", "expected": reviewed["expected"], "offset": 0, "count": 12}, "t" * 43)
            self.assertEqual(code, 200)
            self.assertEqual(base64.b64decode(inspected["data"]), (self.music / "tone.mp3").read_bytes()[:12])
            self.assertEqual(request("POST", "/v1/files/review-delete", {"path": "../tone.mp3"}, "t" * 43)[0], 400)
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

    def delete_entry(self, name="tone.mp3"):
        self.engine.allow_deletion = True
        return self.engine.review_deletion(name)

    def delete(self, entry, **options):
        return self.engine.delete(entry, str(uuid.uuid4()), 0, lambda: False, lambda outcome: None, **options)

    def test_deletion_is_disabled_by_default_and_accepts_only_explicit_operation(self):
        with self.assertRaisesRegex(ServiceError, "not enabled"):
            self.engine.review_deletion("tone.mp3")
        entry = self.delete_entry()
        request = {"version": 1, "operation": "delete", "files": [entry]}
        validate_request(request)
        for altered in ({**request, "operation": "remove"},
                        {**request, "files": [{**entry, "changes": {"genre": "Jazz"}}]},
                        {**request, "files": [entry, entry]}):
            with self.assertRaises(ServiceError):
                validate_request(altered)
        self.engine.allow_deletion = False
        with self.assertRaisesRegex(ServiceError, "not enabled"):
            self.delete(entry)
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        try:
            with self.assertRaisesRegex(ServiceError, "not enabled"):
                store.submit(str(uuid.uuid4()), request)
        finally:
            store.close()

    def test_review_and_dry_run_do_not_mutate_then_delete_only_exact_song(self):
        cover = self.music / "cover.jpg"
        cover.write_bytes(b"keep artwork")
        path = self.music / "tone.mp3"
        before = path.read_bytes()
        entry = self.delete_entry()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(self.delete(entry, dry_run=True)["status"], "validated")
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(self.delete(entry)["status"], "deleted")
        self.assertFalse(path.exists())
        self.assertEqual(cover.read_bytes(), b"keep artwork")
        self.assertTrue((self.music / "tone.flac").exists())
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_delete_empty_audio_but_never_links_or_non_music(self):
        self.engine.allow_deletion = True
        empty = self.music / "empty.wav"
        empty.touch()
        entry = self.engine.review_deletion(empty.name)
        validate_request({"version": 1, "operation": "delete", "files": [entry]})
        self.assertEqual(self.delete(entry)["status"], "deleted")
        (self.music / "link.mp3").symlink_to(self.music / "tone.mp3")
        os.link(self.music / "tone.flac", self.music / "hard.flac")
        for name in ("../tone.mp3", "link.mp3", "hard.flac", "cover.jpg"):
            with self.subTest(name=name), self.assertRaises(ServiceError):
                self.engine.review_deletion(name)

    def test_inspection_returns_only_bytes_from_the_matching_full_file_hash(self):
        path = self.music / "large.wav"
        data = bytes(range(256)) * 8193
        path.write_bytes(data)
        entry = self.delete_entry(path.name)
        for offset, count in ((0, 16), (1024 * 1024 - 7, 23), (len(data), 0), (123, 1024 * 1024)):
            value = self.engine.inspection_read({**entry, "offset": offset, "count": count})
            self.assertEqual(base64.b64decode(value["data"]), data[offset:offset + count])
            self.assertEqual(value["expected"], entry["expected"])
        stat = path.stat()
        changed = bytearray(data); changed[-1] ^= 1
        path.write_bytes(changed)
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        with self.assertRaisesRegex(ServiceError, "no longer matches"):
            self.engine.inspection_read({**entry, "offset": 0, "count": 16})
        self.assertEqual(path.read_bytes(), changed)

    def test_inspection_bounds_and_permission_are_enforced(self):
        entry = self.delete_entry()
        for offset, count in ((-1, 1), (0, -1), (0, 1024 * 1024 + 1), (entry["expected"]["size"], 1), (False, 1), (0, True)):
            with self.subTest(offset=offset, count=count), self.assertRaises(ServiceError):
                self.engine.inspection_read({**entry, "offset": offset, "count": count})
        self.engine.allow_deletion = False
        with self.assertRaisesRegex(ServiceError, "not enabled"):
            self.engine.inspection_read({**entry, "offset": 0, "count": 1})

    def test_delete_rejects_changed_bytes_even_when_size_and_mtime_are_preserved(self):
        path = self.music / "tone.mp3"
        entry = self.delete_entry()
        stat = path.stat()
        data = bytearray(path.read_bytes()); data[-1] ^= 1
        path.write_bytes(data)
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        with self.assertRaisesRegex(ServiceError, "changed"):
            self.delete(entry)
        self.assertEqual(path.read_bytes(), data)

    def test_path_replacement_during_capture_is_restored_without_deleting_either_file(self):
        path = self.music / "tone.mp3"
        original = path.read_bytes()
        entry = self.delete_entry()
        def replace():
            path.rename(self.music / "moved.mp3")
            path.write_bytes(b"a different song")
        with self.assertRaisesRegex(ServiceError, "replaced"):
            self.delete(entry, before_capture=replace)
        self.assertEqual(path.read_bytes(), b"a different song")
        self.assertEqual((self.music / "moved.mp3").read_bytes(), original)
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_in_place_change_after_capture_is_preserved_instead_of_deleted(self):
        path = self.music / "tone.mp3"
        entry = self.delete_entry()
        descriptor = os.open(path, os.O_WRONLY)
        def modify():
            os.write(descriptor, b"modified by another writer")
            os.fsync(descriptor)
        try:
            with self.assertRaisesRegex(ServiceError, "changed"):
                self.delete(entry, after_capture=modify)
        finally:
            os.close(descriptor)
        self.assertTrue(path.read_bytes().startswith(b"modified by another writer"))
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_cancel_after_capture_restores_original(self):
        path = self.music / "tone.mp3"
        original = path.read_bytes()
        entry = self.delete_entry()
        stopped = False
        def stop():
            nonlocal stopped
            stopped = True
        with self.assertRaises(Cancelled):
            self.engine.delete(entry, str(uuid.uuid4()), 0, lambda: stopped, lambda outcome: None, after_capture=stop)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_recovery_never_overwrites_a_new_file_at_original_path(self):
        path = self.music / "tone.mp3"
        original = path.read_bytes()
        entry = self.delete_entry()
        def replace_and_fail():
            path.write_bytes(b"new song")
            raise ServiceError("test", "Stopped")
        with self.assertRaises(ServiceError) as raised:
            self.delete(entry, after_capture=replace_and_fail)
        self.assertEqual(raised.exception.code, "recovery_required")
        self.assertEqual(path.read_bytes(), b"new song")
        recovery = list(self.music.glob(".gumbo-tag-*.deleting/original"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].read_bytes(), original)

    def test_delete_job_lost_ack_replay_restart_and_uncertainty_stops_batch(self):
        request = {"version": 1, "operation": "delete", "files": [self.delete_entry()]}
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        identifier = str(uuid.uuid4())
        store.submit(identifier, request)
        store.run_job(identifier)
        self.assertEqual(store.status(identifier)["files"][0]["status"], "deleted")
        store.close()
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        replay, created = store.submit(identifier, request)
        self.assertFalse(created)
        self.assertEqual(replay["files"][0]["status"], "deleted")
        request = {"version": 1, "operation": "delete", "files": [self.delete_entry("tone.flac"), self.delete_entry("tone.m4a")]}
        identifier = str(uuid.uuid4())
        store.submit(identifier, request)
        save = store._save
        failed = False
        def lose_first_ack(identifier, result):
            nonlocal failed
            if not failed and result["files"][0]["status"] == "deleted":
                failed = True
                raise OSError("lost state write")
            save(identifier, result)
        with patch.object(store, "_save", side_effect=lose_first_ack):
            store.run_job(identifier)
        self.assertEqual([x["status"] for x in store.status(identifier)["files"]], ["unconfirmed", "cancelled"])
        self.assertFalse((self.music / "tone.flac").exists())
        self.assertTrue((self.music / "tone.m4a").exists())
        store.close()

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


    # Issue #256: a failed rollback after replacement must be unconfirmed and stop the batch.
    def test_failed_rollback_after_replacement_is_unconfirmed_and_stops_batch(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        identifier = str(uuid.uuid4())
        flac, mp3 = self.music / "tone.flac", self.music / "tone.mp3"
        flac_before, mp3_before = flac.read_bytes(), mp3.read_bytes()
        store.submit(identifier, {"version": 1, "files": [self.edit("tone.flac"), self.edit("tone.mp3")]})
        real_replace, calls = os.replace, []
        def replace(*args, **kwargs):
            calls.append(args)
            if len(calls) == 2:  # The rollback of the first file's replacement.
                raise OSError(errno.EIO, "I/O error")
            return real_replace(*args, **kwargs)
        real_execute = self.engine.execute
        def execute(entry, *args, **kwargs):
            if entry["path"] == "tone.flac":
                def fail():
                    raise OSError(errno.EIO, "fsync failed after replace")
                kwargs["after_replace"] = fail
            return real_execute(entry, *args, **kwargs)
        with patch("engine.os.replace", side_effect=replace), patch.object(self.engine, "execute", side_effect=execute):
            store.run_job(identifier)
        status = store.status(identifier)
        self.assertEqual(status["status"], "partial")
        self.assertEqual([item["status"] for item in status["files"]], ["unconfirmed", "cancelled"])
        self.assertEqual(status["files"][0]["error"]["code"], "recovery_required")
        self.assertNotEqual(flac.read_bytes(), flac_before)
        backups = list(self.music.glob(".gumbo-tag-*.backup"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), flac_before)
        self.assertEqual(mp3.read_bytes(), mp3_before)
        store.close()

    def test_rollback_fsync_failure_restores_original_but_is_unconfirmed(self):
        path = self.music / "tone.flac"
        before = path.read_bytes()
        real_fsync, real_replace, rolled_back = os.fsync, os.replace, []
        def replace(source, destination, **kwargs):
            if source.endswith(".backup"):
                rolled_back.append(True)
            return real_replace(source, destination, **kwargs)
        def fsync(descriptor):
            if rolled_back:
                raise OSError(errno.EIO, "I/O error")
            return real_fsync(descriptor)
        def fail():
            raise OSError(errno.EIO, "read failed after replace")
        with patch("engine.os.replace", side_effect=replace), patch("engine.os.fsync", side_effect=fsync), \
                self.assertRaises(ServiceError) as raised:
            self.execute(self.edit(path.name), after_replace=fail)
        self.assertEqual(raised.exception.code, "recovery_required")
        self.assertEqual(path.read_bytes(), before)

    def test_os_error_after_replacement_rolls_back_and_reports_real_cause(self):
        path = self.music / "tone.flac"
        before = path.read_bytes()
        def fail():
            raise OSError(errno.EIO, "fsync failed after replace")
        with self.assertRaises(ServiceError) as raised:
            self.execute(self.edit(path.name), after_replace=fail)
        self.assertEqual((raised.exception.code, raised.exception.status), ("io_error", 500))
        self.assertIn("EIO", raised.exception.message)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_os_errors_map_to_accurate_codes_and_keep_original(self):
        path = self.music / "tone.flac"
        before = path.read_bytes()
        real_open = os.open
        def deny_stage(name, flags, mode=0o777, *, dir_fd=None):
            if isinstance(name, str) and name.endswith(".tmp"):
                raise PermissionError(errno.EACCES, "Permission denied")
            return real_open(name, flags, mode, dir_fd=dir_fd)
        def raising(number):
            def fail(*args, **kwargs):
                raise OSError(number, os.strerror(number))
            return fail
        cases = [
            (patch("engine.os.open", side_effect=deny_stage), "permission_denied", 409),
            (patch("engine.copy_extended_attributes", side_effect=raising(errno.EPERM)), "permission_denied", 409),
            (patch("engine.os.fsync", side_effect=raising(errno.ENOSPC)), "insufficient_space", 507),
            (patch("engine.os.fsync", side_effect=raising(errno.EDQUOT)), "insufficient_space", 507),
            (patch("engine.os.link", side_effect=raising(errno.EROFS)), "permission_denied", 409),
            (patch("engine.os.fsync", side_effect=raising(errno.EIO)), "io_error", 500),
            (patch("engine.fcntl.flock", side_effect=raising(errno.EWOULDBLOCK)), "file_busy", 409),
        ]
        for patcher, code, status in cases:
            with self.subTest(code=code, patched=patcher.attribute):
                edit = self.edit(path.name)
                with patcher, self.assertRaises(ServiceError) as raised:
                    self.execute(edit)
                self.assertEqual((raised.exception.code, raised.exception.status), (code, status))
                self.assertNotIn("symbolic link", raised.exception.message)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(list(self.music.glob(".gumbo-tag-*")), [])

    def test_path_errors_still_report_missing_or_symbolic_link(self):
        (self.music / "folder").mkdir()
        (self.music / "linked").symlink_to(self.music / "folder", target_is_directory=True)
        (self.music / "linked.mp3").symlink_to(self.music / "tone.mp3")
        for path in ("absent.mp3", "absent/tone.mp3", "linked/tone.mp3", "linked.mp3", "tone.mp3/tone.mp3"):
            with self.subTest(path=path), self.assertRaises(ServiceError) as raised:
                self.engine.inspect(path)
            self.assertEqual((raised.exception.code, raised.exception.status), ("unsafe_or_missing_path", 409))
        real_open = os.open
        def deny_folder(name, flags, mode=0o777, *, dir_fd=None):
            if name == "folder":
                raise PermissionError(errno.EACCES, "Permission denied")
            return real_open(name, flags, mode, dir_fd=dir_fd)
        with patch("engine.os.open", side_effect=deny_folder), self.assertRaises(ServiceError) as raised:
            self.engine.inspect("folder/tone.mp3")
        self.assertEqual(raised.exception.code, "permission_denied")

    def test_storage_error_mapping_and_ordinary_failure_does_not_stop_batch(self):
        for number, code in ((errno.EAGAIN, "file_busy"), (errno.EBUSY, "file_busy"), (errno.EEXIST, "conflict"),
                             (errno.ENOTDIR, "unsafe_or_missing_path"), (errno.ELOOP, "unsafe_or_missing_path"), (None, "io_error")):
            with self.subTest(number=number):
                self.assertEqual(storage_error(OSError(number, "x") if number else OSError("x")).code, code)
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        identifier = str(uuid.uuid4())
        store.submit(identifier, {"version": 1, "files": [self.edit("tone.flac"), self.edit("tone.mp3")]})
        real_execute = self.engine.execute
        def execute(entry, *args, **kwargs):
            if entry["path"] == "tone.flac":
                with patch("engine.os.fsync", side_effect=OSError(errno.ENOSPC, "No space left on device")):
                    return real_execute(entry, *args, **kwargs)
            return real_execute(entry, *args, **kwargs)
        with patch.object(self.engine, "execute", side_effect=execute):
            store.run_job(identifier)
        files = store.status(identifier)["files"]
        self.assertEqual([item["status"] for item in files], ["failed", "succeeded"])
        self.assertEqual(files[0]["error"]["code"], "insufficient_space")
        self.assertEqual((self.music / "tone.flac").read_bytes(), (FIXTURES / "tone.flac").read_bytes())
        store.close()

    def test_http_reports_storage_errors_with_their_codes(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        server = HTTPServer(("127.0.0.1", 0), self.engine, store, "t" * 43)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            def stat(path):
                connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                connection.request("POST", "/v1/files/stat", json.dumps({"path": path}).encode(),
                                   {"Content-Type": "application/json", "Authorization": "Bearer " + "t" * 43})
                response = connection.getresponse()
                data = json.loads(response.read())
                connection.close()
                return response.status, data["error"]["code"]
            with patch("engine.digest", side_effect=OSError(errno.EIO, "I/O error")):
                self.assertEqual(stat("tone.mp3"), (500, "io_error"))
            with patch("engine.digest", side_effect=PermissionError(errno.EACCES, "Permission denied")):
                self.assertEqual(stat("tone.mp3"), (409, "permission_denied"))
            self.assertEqual(stat("absent.mp3"), (409, "unsafe_or_missing_path"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            store.close()

    def serve(self):
        store = JobStore(self.base / "state", self.engine, start_worker=False)
        server = HTTPServer(("127.0.0.1", 0), self.engine, store, "t" * 43)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join()
            store.close()
        self.addCleanup(stop)
        return server

    def authorized(self, server, method, route, body=None, source=None):
        connection = http.client.HTTPConnection(*server.server_address, timeout=5, source_address=source)
        try:
            connection.request(method, route, json.dumps(body).encode() if body is not None else None,
                               {"Content-Type": "application/json", "Authorization": "Bearer " + "t" * 43})
            response = connection.getresponse()
            data = json.loads(response.read())
            return response.status, data.get("error", {}).get("code")
        finally:
            connection.close()

    def assert_closed_by_server(self, client, within):
        client.settimeout(within)
        try:
            self.assertEqual(client.recv(1024), b"")
        except ConnectionResetError:
            pass

    def test_slow_drip_request_is_closed_at_its_absolute_deadline(self):
        with patch("server.REQUEST_DEADLINE", 0.5):
            server = self.serve()
            client = socket.create_connection(server.server_address, timeout=5)
            self.addCleanup(client.close)
            # Each byte arrives well within any per-recv timeout; only the total deadline stops it.
            with contextlib.suppress(OSError):
                for byte in b"GET /v1/capabilities HTTP/1.0\r\nX-Slow: aaaaaaaaaaaa":
                    client.sendall(bytes([byte]))
                    time.sleep(0.05)
            self.assert_closed_by_server(client, 2)

    def test_one_address_cannot_occupy_every_connection_or_lock_out_other_clients(self):
        server = self.serve()
        idle = [socket.create_connection(server.server_address, timeout=5) for _ in range(MAX_CONNECTIONS_PER_ADDRESS)]
        for connection in idle:
            self.addCleanup(connection.close)
        deadline = time.monotonic() + 5
        while server.connections.get("127.0.0.1", 0) < MAX_CONNECTIONS_PER_ADDRESS and time.monotonic() < deadline:
            time.sleep(0.01)
        extra = socket.create_connection(server.server_address, timeout=5)
        self.addCleanup(extra.close)
        self.assert_closed_by_server(extra, 2)
        try:
            self.assertEqual(self.authorized(server, "GET", "/v1/capabilities", source=("127.0.0.2", 0)), (200, None))
        except OSError:
            self.skipTest("A second loopback address isn't available on this host.")
        for connection in idle:
            connection.close()

    def test_job_polls_are_answered_while_every_work_slot_is_busy(self):
        server = self.serve()
        for _ in range(MAX_ACTIVE_REQUESTS):
            server.work.acquire()
        try:
            self.assertEqual(self.authorized(server, "POST", "/v1/files/stat", {"path": "tone.mp3"}), (503, "busy"))
            identifier = str(uuid.uuid4())
            self.assertEqual(self.authorized(server, "GET", "/v1/jobs/" + identifier), (404, "job_not_found"))
            self.assertEqual(self.authorized(server, "POST", "/v1/jobs/" + identifier + "/cancel", {}), (404, "job_not_found"))
        finally:
            for _ in range(MAX_ACTIVE_REQUESTS):
                server.work.release()
        self.assertEqual(self.authorized(server, "POST", "/v1/files/stat", {"path": "tone.mp3"}), (200, None))

    def test_format_characters_are_accepted_and_only_ascii_controls_rejected(self):
        # ZWNJ, ZWJ, LRM, soft hyphen and BOM are ordinary text; the Swift client applies the same rule.
        for text in ("\u062f\u0644\u062a\u0646\u06af\u200c\u06cc", "\U0001F469\u200d\U0001F3A4", "a\u200eb", "soft\u00adhyphen", "\ufeffBOM"):
            with self.subTest(text=text):
                entry = self.edit()
                entry["changes"] = {"album": text}
                validate_request({"version": 1, "files": [entry]})
                entry["path"] = text + ".mp3"
                validate_request({"version": 1, "files": [entry]})
        for text in ("tab\there", "unit\x1fseparator", "delete\x7f"):
            with self.subTest(text=text), self.assertRaises(ServiceError):
                entry = self.edit()
                entry["changes"] = {"album": text}
                validate_request({"version": 1, "files": [entry]})

if __name__ == "__main__":
    unittest.main()
