# SPDX-License-Identifier: GPL-2.0-or-later
"""Constrained, local-only file replacement. This module never invokes a shell."""
import base64
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import time
from pathlib import PurePosixPath

import mutagen
from mutagen.flac import FLAC
from mutagen.id3 import TALB, TPE2, TCON
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4

CHUNK = 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_FILES = 128
FIELDS = {"album", "albumArtist", "genre"}
SUFFIXES = {".mp3", ".flac", ".m4a"}
DELETE_SUFFIXES = {"." + value for value in ("flac mp3 m4a aac alac wav aif aiff ogg oga opus wma ape wv dsf dff mp4 caf").split()}


class ServiceError(Exception):
    def __init__(self, code, message, status=400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


class Cancelled(ServiceError):
    def __init__(self):
        super().__init__("cancelled", "Stopped before replacing the file.", 409)


def check_cancel(cancelled):
    if cancelled():
        raise Cancelled()


def relative_parts(path, deletion=False):
    if not isinstance(path, str) or not path or len(path.encode("utf-8")) > 4096:
        raise ServiceError("invalid_path", "Use a relative music file path.")
    parts = path.split("/")
    if any(part in ("", ".", "..") or part.startswith(".gumbo-tag-") for part in parts):
        raise ServiceError("invalid_path", "Empty, parent and reserved path components are not allowed.")
    if "\\" in path or any(ord(char) < 32 or ord(char) == 127 for char in path):
        raise ServiceError("invalid_path", "The path contains unsupported characters.")
    if PurePosixPath(path).suffix.lower() not in (DELETE_SUFFIXES if deletion else SUFFIXES):
        raise ServiceError("unsupported_format", "Only recognized music files can be deleted." if deletion else "Only MP3, FLAC and M4A files can be edited.")
    return parts


def validate_request(value):
    if not isinstance(value, dict) or set(value) - {"version", "files", "dryRun", "operation"}:
        raise ServiceError("invalid_request", "Unknown request fields.")
    if value.get("operation", "tags") not in ("tags", "delete"):
        raise ServiceError("invalid_request", "Unknown operation.")
    deletion = value.get("operation") == "delete"
    if type(value.get("version")) is not int or value["version"] != 1:
        raise ServiceError("unsupported_version", "Use request version 1.")
    if "dryRun" in value and type(value["dryRun"]) is not bool:
        raise ServiceError("invalid_request", "dryRun must be a boolean.")
    files = value.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= MAX_FILES:
        raise ServiceError("invalid_request", "A job must contain between 1 and 128 files.")
    paths = set()
    for entry in files:
        allowed = {"path", "expected"} if deletion else {"path", "expected", "changes", "onlyIfGenreMissing"}
        required = {"path", "expected"} if deletion else {"path", "expected", "changes"}
        if not isinstance(entry, dict) or set(entry) - allowed or not required <= set(entry):
            raise ServiceError("invalid_request", "Each deletion needs only path and expected." if deletion else "Each file needs path, expected and changes.")
        if "onlyIfGenreMissing" in entry and type(entry["onlyIfGenreMissing"]) is not bool:
            raise ServiceError("invalid_request", "onlyIfGenreMissing must be a boolean.")
        relative_parts(entry["path"], deletion=deletion)
        if entry["path"] in paths:
            raise ServiceError("invalid_request", "A file may appear only once in a job.")
        paths.add(entry["path"])
        expected = entry["expected"]
        if not isinstance(expected, dict) or set(expected) != {"size", "mtimeNs", "sha256"}:
            raise ServiceError("invalid_request", "Expected size, mtimeNs and sha256 are required.")
        if type(expected["size"]) is not int or not (0 if deletion else 1) <= expected["size"] <= MAX_FILE_BYTES:
            raise ServiceError("invalid_request", "The file exceeds the supported size limit.")
        if type(expected["mtimeNs"]) is not int or expected["mtimeNs"] < 0:
            raise ServiceError("invalid_request", "mtimeNs must be a nonnegative integer.")
        if not isinstance(expected["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]):
            raise ServiceError("invalid_request", "sha256 must be a lowercase SHA-256 digest.")
        if deletion:
            continue
        changes = entry["changes"]
        if not isinstance(changes, dict) or not changes or set(changes) - FIELDS:
            raise ServiceError("invalid_request", "Only album, albumArtist and genre may be changed.")
        if entry.get("onlyIfGenreMissing", False) and set(changes) != {"genre"}:
            raise ServiceError("invalid_request", "onlyIfGenreMissing is only valid for a genre-only edit.")
        for text in changes.values():
            if not isinstance(text, str) or not text.strip() or len(text.encode("utf-8")) > 1024:
                raise ServiceError("invalid_request", "Tag values must contain between 1 and 1024 UTF-8 bytes.")
            if any(ord(char) < 32 or ord(char) == 127 for char in text):
                raise ServiceError("invalid_request", "Tag values may not contain control characters.")
    return value


def digest(stream, start=0, length=None, cancelled=lambda: False):
    stream.seek(start)
    result = hashlib.sha256()
    remaining = length
    while remaining is None or remaining > 0:
        check_cancel(cancelled)
        block = stream.read(CHUNK if remaining is None else min(CHUNK, remaining))
        if not block:
            if remaining:
                raise ServiceError("invalid_file", "The file ended unexpectedly.")
            break
        result.update(block)
        if remaining is not None:
            remaining -= len(block)
    return result.hexdigest()


def stamp(info, sha256):
    return {"size": info.st_size, "mtimeNs": info.st_mtime_ns, "sha256": sha256}


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def canonical(value):
    """Compare semantic tag values, including artwork and unknown binary frames."""
    if isinstance(value, bytes):
        return ("bytes", len(value), hashlib.sha256(value).hexdigest())
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return {str(key): canonical(item) for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))}
    if isinstance(value, (list, tuple)):
        return [canonical(item) for item in value]
    if hasattr(value, "__dict__"):
        return (type(value).__name__, canonical(vars(value)))
    raise ServiceError("unsupported_tags", "This file has tags that cannot be verified safely.")


def tag_keys(audio, changes):
    if isinstance(audio, MP3):
        mapping = {"album": "TALB", "albumArtist": "TPE2", "genre": "TCON"}
    elif isinstance(audio, FLAC):
        mapping = {"album": "album", "albumArtist": "albumartist", "genre": "genre"}
    else:
        mapping = {"album": "\xa9alb", "albumArtist": "aART", "genre": "\xa9gen"}
    return {field: mapping[field] for field in changes}


def unrelated_tags(audio, changes):
    ignored = set(tag_keys(audio, changes).values())
    tags = audio.tags or {}
    result = {key: canonical(value) for key, value in tags.items() if key not in ignored}
    if isinstance(audio, MP3):
        result["_unknown_frames"] = canonical(getattr(audio.tags, "unknown_frames", []))
    elif isinstance(audio, MP4):
        result["_unknown_atoms"] = canonical(getattr(audio.tags, "_failed_atoms", {}))
    elif isinstance(audio, FLAC):
        result["_vendor"] = getattr(audio.tags, "vendor", None)
    return result


def field_values(audio, field):
    key = tag_keys(audio, {field: ""})[field]
    value = (audio.tags or {}).get(key, [])
    if isinstance(audio, MP3) and value:
        value = value.genres if field == "genre" else value.text
    return [str(item) for item in value]


def fields(audio):
    result = {}
    for field in ("album", "albumArtist", "genre"):
        values = field_values(audio, field)
        present = [value for value in values if value.strip()]
        if field == "genre":
            present = [value for value in present if value.strip().lower() not in ("unknown", "unknown genre", "no genre")] or present
        result[field] = present[0] if present else None
    return result


def load_audio(stream, path):
    stream.seek(0)
    suffix = PurePosixPath(path).suffix.lower()
    bound_metadata(stream, suffix)
    stream.seek(0)
    try:
        audio = {".mp3": MP3, ".flac": FLAC, ".m4a": MP4}[suffix](stream)
    except (mutagen.MutagenError, ValueError, OSError) as error:
        raise ServiceError("invalid_file", "The file could not be read as supported audio.") from error
    if audio.info.length <= 0:
        raise ServiceError("invalid_file", "The file has no readable audio duration.")
    if isinstance(audio, MP4) and not str(getattr(audio.info, "codec", "")).startswith(("mp4a", "alac")):
        raise ServiceError("unsupported_format", "Only AAC or ALAC audio in M4A is supported.")
    return audio


def bound_metadata(stream, suffix):
    """Refuse oversized tag areas before a parser can allocate their advertised size."""
    limit = 32 * CHUNK
    size = os.fstat(stream.fileno()).st_size
    stream.seek(0)
    if suffix == ".mp3":
        header = stream.read(10)
        if header[:3] == b"ID3":
            if len(header) != 10 or any(byte & 128 for byte in header[6:10]):
                raise ServiceError("invalid_file", "Invalid ID3 header.")
            length = sum(byte << shift for byte, shift in zip(header[6:10], (21, 14, 7, 0)))
            if length > limit or length + 10 > size:
                raise ServiceError("metadata_too_large", "The file's tags exceed safe parser limits.", 422)
        return
    if suffix == ".flac":
        if stream.read(4) != b"fLaC":
            raise ServiceError("unsupported_format", "Only native FLAC files are supported.")
        for _ in range(4096):
            header = stream.read(4)
            if len(header) != 4:
                raise ServiceError("invalid_file", "Invalid FLAC metadata.")
            length = int.from_bytes(header[1:], "big")
            following = stream.tell() + length
            if following > min(size, limit):
                raise ServiceError("metadata_too_large", "The file's tags exceed safe parser limits.", 422)
            stream.seek(following)
            if header[0] & 128:
                return
        raise ServiceError("invalid_file", "Too many FLAC metadata blocks.")
    offset = 0
    for _ in range(100000):
        if offset == size:
            return
        stream.seek(offset)
        header = stream.read(8)
        if len(header) != 8:
            raise ServiceError("invalid_file", "Invalid MP4 atom.")
        length, kind = struct.unpack(">I4s", header)
        minimum = 8
        if length == 1:
            extra = stream.read(8)
            if len(extra) != 8:
                raise ServiceError("invalid_file", "Invalid MP4 atom.")
            length, minimum = struct.unpack(">Q", extra)[0], 16
        elif length == 0:
            length = size - offset
        if length < minimum or offset + length > size:
            raise ServiceError("invalid_file", "Invalid MP4 atom bounds.")
        if kind == b"moov" and length > limit:
            raise ServiceError("metadata_too_large", "The file's tags exceed safe parser limits.", 422)
        offset += length
    raise ServiceError("invalid_file", "Too many MP4 atoms.")


def media_signature(stream, audio, changes, cancelled):
    """Hash encoded media bytes, not decoded approximations; include non-tag container metadata."""
    size = os.fstat(stream.fileno()).st_size
    properties = tuple(getattr(audio.info, name, None) for name in ("length", "sample_rate", "channels", "codec"))
    if isinstance(audio, MP3):
        stream.seek(0)
        header = stream.read(10)
        start = 0
        if header[:3] == b"ID3":
            if len(header) != 10 or any(byte & 0x80 for byte in header[6:10]):
                raise ServiceError("invalid_file", "Invalid ID3 header.")
            start = 10 + sum(byte << shift for byte, shift in zip(header[6:10], (21, 14, 7, 0)))
        stream.seek(max(0, size - 128))
        footer = stream.read(128)
        end = size
        old_tag = None
        if footer[:3] == b"TAG":
            end -= 128
            old_tag = bytearray(footer)
            if "album" in changes:
                old_tag[63:93] = b"\0" * 30
            if "genre" in changes:
                old_tag[127] = 0
            old_tag = bytes(old_tag)
        if start >= end:
            raise ServiceError("invalid_file", "No MPEG audio payload was found.")
        return (properties, digest(stream, start, end - start, cancelled), old_tag)
    if isinstance(audio, FLAC):
        stream.seek(0)
        if stream.read(4) != b"fLaC":
            raise ServiceError("unsupported_format", "FLAC files with leading foreign tags are not supported.")
        blocks = []
        for _ in range(4096):
            header = stream.read(4)
            if len(header) != 4:
                raise ServiceError("invalid_file", "Invalid FLAC metadata.")
            kind, length = header[0] & 127, int.from_bytes(header[1:], "big")
            start = stream.tell()
            if kind not in (1, 4):  # Padding may move; comments are verified as individual tags.
                blocks.append((kind, digest(stream, start, length, cancelled)))
            stream.seek(start + length)
            if header[0] & 128:
                offset = stream.tell()
                return (properties, blocks, digest(stream, offset, size - offset, cancelled))
        raise ServiceError("invalid_file", "Too many FLAC metadata blocks.")
    atoms, media = [], []
    offset = 0
    while offset < size:
        check_cancel(cancelled)
        stream.seek(offset)
        header = stream.read(8)
        if len(header) != 8:
            raise ServiceError("invalid_file", "Invalid MP4 atom.")
        length, kind = struct.unpack(">I4s", header)
        header_size = 8
        if length == 1:
            extended = stream.read(8)
            if len(extended) != 8:
                raise ServiceError("invalid_file", "Invalid extended MP4 atom.")
            length, header_size = struct.unpack(">Q", extended)[0], 16
        elif length == 0:
            length = size - offset
        if length < header_size or offset + length > size:
            raise ServiceError("invalid_file", "MP4 atom extends beyond the file.")
        if kind == b"mdat":
            media.append(digest(stream, offset + header_size, length - header_size, cancelled))
        elif kind not in (b"moov", b"free"):
            atoms.append((kind, digest(stream, offset + header_size, length - header_size, cancelled)))
        offset += length
    if not media:
        raise ServiceError("invalid_file", "No MP4 audio payload was found.")
    return (properties, atoms, media)


def rewrite(stream, path, changes, cancelled):
    before = load_audio(stream, path)
    unrelated = unrelated_tags(before, changes)
    media = media_signature(stream, before, changes, cancelled)
    id3_version = getattr(before.tags, "version", (2, 4, 0))[1] if isinstance(before, MP3) else None
    if before.tags is None:
        before.add_tags()
    keys = tag_keys(before, changes)
    for field, text in changes.items():
        key = keys[field]
        if isinstance(before, MP3):
            before.tags.setall(key, [{"album": TALB, "albumArtist": TPE2, "genre": TCON}[field](encoding=3, text=[text])])
        else:
            before.tags[key] = [text]
    check_cancel(cancelled)
    stream.seek(0)
    if isinstance(before, MP3):
        before.save(stream, v1=1, v2_version=3 if id3_version == 3 else 4)
    else:
        before.save(stream)
    stream.flush()
    after = load_audio(stream, path)
    if unrelated_tags(after, changes) != unrelated or media_signature(stream, after, changes, cancelled) != media:
        raise ServiceError("verification_failed", "Audio or unrelated tags changed; the original was kept.", 422)
    for field, key in keys.items():
        value = after.tags[key]
        if isinstance(after, MP3):
            value = value.text
        if list(value) != [changes[field]]:
            raise ServiceError("verification_failed", "The requested tags did not round-trip correctly.", 422)


def copy_extended_attributes(source, destination):
    if hasattr(os, "listxattr"):
        for attribute in os.listxattr(source):
            os.setxattr(destination, attribute, os.getxattr(source, attribute))
        return
    if sys.platform != "darwin":
        raise ServiceError("unsupported_filesystem", "This platform cannot safely preserve extended attributes.")
    # macOS development fixtures use the same fd-only semantics as Linux; never reopen by pathname.
    library = ctypes.CDLL(None, use_errno=True)
    for name in ("flistxattr", "fgetxattr"):
        getattr(library, name).restype = ctypes.c_ssize_t
    count = library.flistxattr(source, None, 0, 0)
    if count < 0:
        raise OSError(ctypes.get_errno(), "Cannot read extended attributes")
    names = ctypes.create_string_buffer(count)
    if library.flistxattr(source, names, count, 0) < 0:
        raise OSError(ctypes.get_errno(), "Cannot list extended attributes")
    for name in names.raw.split(b"\0"):
        if not name:
            continue
        size = library.fgetxattr(source, name, None, 0, 0, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "Cannot read extended attribute")
        value = ctypes.create_string_buffer(size)
        if library.fgetxattr(source, name, value, size, 0, 0) < 0 or library.fsetxattr(destination, name, value, size, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Cannot preserve extended attribute")


class FileEngine:
    def __init__(self, music_root, allow_deletion=False):
        self.root = os.path.abspath(music_root)
        self.root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.allow_deletion = allow_deletion

    def close(self):
        os.close(self.root_fd)

    @contextlib.contextmanager
    def parent(self, path, deletion=False):
        parts = relative_parts(path, deletion=deletion)
        descriptor = os.dup(self.root_fd)
        try:
            for part in parts[:-1]:
                following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = following
            yield descriptor, parts[-1]
        except OSError as error:
            raise ServiceError("unsafe_or_missing_path", "The file is missing, inaccessible or uses a symbolic link.", 409) from error
        finally:
            os.close(descriptor)

    @contextlib.contextmanager
    def source(self, parent, name, allow_empty=False):
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not (0 if allow_empty else 1) <= info.st_size <= MAX_FILE_BYTES:
                raise ServiceError("unsafe_file", "Use a regular, non-hard-linked music file no larger than 2 GiB.", 409)
            yield stream, info

    def inspect(self, path):
        with self.parent(path) as (parent, name), self.source(parent, name) as (stream, info):
            sha = digest(stream)
            current_fields = fields(load_audio(stream, path))
            if identity(os.fstat(stream.fileno())) != identity(info):
                raise ServiceError("conflict", "The file changed while it was being inspected.", 409)
            return {"path": path, "expected": stamp(info, sha), "fields": current_fields}

    def review_deletion(self, path):
        if not self.allow_deletion:
            raise ServiceError("deletion_disabled", "Reviewed deletion is not enabled by this server's owner.", 403)
        with self.parent(path, deletion=True) as (parent, name), self.source(parent, name, allow_empty=True) as (source, info):
            fcntl.flock(source.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
            sha = digest(source)
            if identity(os.fstat(source.fileno())) != identity(info) or identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != identity(info):
                raise ServiceError("conflict", "The file changed during review.", 409)
            return {"path": path, "expected": stamp(info, sha)}

    def inspection_read(self, value):
        if not self.allow_deletion:
            raise ServiceError("deletion_disabled", "Reviewed deletion is not enabled by this server's owner.", 403)
        if not isinstance(value, dict) or set(value) != {"path", "expected", "offset", "count"}:
            raise ServiceError("invalid_request", "Inspection needs path, expected, offset and count.")
        validate_request({"version": 1, "operation": "delete", "files": [{"path": value["path"], "expected": value["expected"]}]})
        offset, count, expected = value["offset"], value["count"], value["expected"]
        if type(offset) is not int or type(count) is not int or offset < 0 or not 0 <= count <= CHUNK or offset + count > expected["size"]:
            raise ServiceError("invalid_request", "Inspection ranges must fit the reviewed file and be at most 1 MiB.")
        with self.parent(value["path"], deletion=True) as (parent, name), self.source(parent, name, allow_empty=True) as (source, original):
            fcntl.flock(source.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
            hashed = hashlib.sha256()
            position = 0
            selected = bytearray()
            # Select returned bytes from the exact same full-file pass that proves the
            # fingerprint. Hashing first and seeking back later would permit a write race.
            while True:
                block = source.read(CHUNK)
                if not block:
                    break
                hashed.update(block)
                start = max(offset, position)
                end = min(offset + count, position + len(block))
                if end > start:
                    selected.extend(block[start - position:end - position])
                position += len(block)
                if position > MAX_FILE_BYTES:
                    raise ServiceError("conflict", "The file grew during inspection.", 409)
            if (position != expected["size"] or len(selected) != count or stamp(original, hashed.hexdigest()) != expected
                    or identity(os.fstat(source.fileno())) != identity(original)
                    or identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != identity(original)):
                raise ServiceError("conflict", "The inspected file no longer matches the reviewed file.", 409)
            return {"path": value["path"], "expected": expected, "offset": offset, "data": base64.b64encode(selected).decode("ascii")}

    def delete(self, entry, operation_id, index, cancelled, persist_success, dry_run=False, before_capture=None, after_capture=None):
        if not self.allow_deletion:
            raise ServiceError("deletion_disabled", "Reviewed deletion is not enabled by this server's owner.", 403)
        path, expected = entry["path"], entry["expected"]
        recovery = ".gumbo-tag-" + operation_id + "-" + str(index) + ".deleting"
        with self.parent(path, deletion=True) as (parent, name), self.source(parent, name, allow_empty=True) as (source, original):
            check_cancel(cancelled)
            if original.st_uid != os.geteuid():
                raise ServiceError("ownership_mismatch", "Run the helper as this music file's owner.", 403)
            try:
                fcntl.flock(source.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise ServiceError("file_busy", "Another cooperating writer is using this file.", 409) from error
            if stamp(original, digest(source, cancelled=cancelled)) != expected or identity(os.fstat(source.fileno())) != identity(original):
                raise ServiceError("conflict", "The file changed; review it again before deleting.", 409)
            if dry_run:
                result = {"path": path, "status": "validated", "before": expected}
                persist_success(result)
                return result
            os.mkdir(recovery, 0o700, dir_fd=parent)
            try:
                recovery_fd = os.open(recovery, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            except OSError:
                with contextlib.suppress(OSError):
                    os.rmdir(recovery, dir_fd=parent)
                raise
            captured, removed = False, False
            try:
                if before_capture:
                    before_capture()
                check_cancel(cancelled)
                with self.parent(path, deletion=True) as (current_parent, _):
                    if (os.fstat(parent).st_dev, os.fstat(parent).st_ino) != (os.fstat(current_parent).st_dev, os.fstat(current_parent).st_ino):
                        raise ServiceError("conflict", "The music folder moved during deletion review.", 409)
                # Move into a newly reserved private directory before unlinking anything. If an
                # external writer wins the source-path race, the captured replacement is restored.
                os.rename(name, "original", src_dir_fd=parent, dst_dir_fd=recovery_fd)
                captured = True
                os.fsync(parent)
                os.fsync(recovery_fd)
                if after_capture:
                    after_capture()
                captured_info = os.stat("original", dir_fd=recovery_fd, follow_symlinks=False)
                if (captured_info.st_dev, captured_info.st_ino) != (original.st_dev, original.st_ino):
                    raise ServiceError("conflict", "Another file replaced the reviewed song; nothing was deleted.", 409)
                if stamp(os.fstat(source.fileno()), digest(source, cancelled=cancelled)) != expected:
                    raise ServiceError("conflict", "The reviewed song changed; nothing was deleted.", 409)
                check_cancel(cancelled)
                os.unlink("original", dir_fd=recovery_fd)
                removed = True
                os.fsync(recovery_fd)
                result = {"path": path, "status": "deleted", "before": expected}
                persist_success(result)
                return result
            except Exception as error:
                if removed:
                    raise ServiceError("recovery_required", "The file may be deleted but its result was not confirmed. Check the original job; do not repeat it.", 500) from error
                if captured:
                    try:
                        # link publishes only if the original path is still absent. Never overwrite
                        # a concurrently created file to restore the captured one.
                        os.link("original", name, src_dir_fd=recovery_fd, dst_dir_fd=parent, follow_symlinks=False)
                        os.unlink("original", dir_fd=recovery_fd)
                        captured = False
                        os.fsync(parent)
                    except OSError as restore_error:
                        raise ServiceError("recovery_required", "No permanent deletion was confirmed. A file remains in " + recovery + "; restore it after checking the original path.", 500) from restore_error
                raise
            finally:
                os.close(recovery_fd)
                if not captured or removed:
                    with contextlib.suppress(OSError):
                        os.rmdir(recovery, dir_fd=parent)
                        os.fsync(parent)

    def execute(self, entry, operation_id, index, cancelled, persist_success, dry_run=False, before_commit=None, after_replace=None):
        path, expected = entry["path"], entry["expected"]
        stage_name = ".gumbo-tag-" + operation_id + "-" + str(index) + ".tmp"
        backup_name = ".gumbo-tag-" + operation_id + "-" + str(index) + ".backup"
        with self.parent(path) as (parent, name), self.source(parent, name) as (source, original):
            check_cancel(cancelled)
            if original.st_uid != os.geteuid():
                raise ServiceError("ownership_mismatch", "Run the helper as the music file's owner so ownership can be preserved.", 403)
            try:
                fcntl.flock(source.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise ServiceError("file_busy", "Another cooperating writer is editing this file.", 409) from error
            sha = digest(source, cancelled=cancelled)
            if stamp(original, sha) != expected or identity(os.fstat(source.fileno())) != identity(original):
                raise ServiceError("conflict", "The file changed; inspect it again before editing.", 409)
            original_audio = load_audio(source, path)
            original_fields = fields(original_audio)
            genre_present = (original_fields["genre"] or "").strip().lower() not in ("", "unknown", "unknown genre", "no genre")
            unchanged = all(field_values(original_audio, key) == [value] for key, value in entry["changes"].items())
            if unchanged or (entry.get("onlyIfGenreMissing", False) and genre_present):
                check_cancel(cancelled)
                if identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != identity(original):
                    raise ServiceError("conflict", "The file changed while reading its current tags.", 409)
                result = {"path": path, "status": "unchanged", "before": expected, "after": {**expected, "fields": original_fields}}
                persist_success(result)
                return result
            available = os.fstatvfs(parent).f_bavail * os.fstatvfs(parent).f_frsize
            if available < original.st_size * 2 + 16 * CHUNK:
                raise ServiceError("insufficient_space", "There is not enough room to stage and recover this file.", 507)
            descriptor = os.open(stage_name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            replaced, backup, durable = False, False, False
            stage_identity = None
            try:
                with os.fdopen(descriptor, "r+b") as staged:
                    source.seek(0)
                    while True:
                        check_cancel(cancelled)
                        block = source.read(CHUNK)
                        if not block:
                            break
                        staged.write(block)
                    staged.flush()
                    rewrite(staged, path, entry["changes"], cancelled)
                    os.fchmod(staged.fileno(), stat.S_IMODE(original.st_mode))
                    if os.fstat(staged.fileno()).st_gid != original.st_gid:
                        os.fchown(staged.fileno(), -1, original.st_gid)
                    copy_extended_attributes(source.fileno(), staged.fileno())
                    # NAS listings may expose only whole seconds; even a same-size edit must be discoverable.
                    modified = max(time.time_ns(), (original.st_mtime_ns // 1_000_000_000 + 1) * 1_000_000_000)
                    os.utime(staged.fileno(), ns=(original.st_atime_ns, modified))
                    os.fsync(staged.fileno())
                    written_fields = fields(load_audio(staged, path))
                    written = {**stamp(os.fstat(staged.fileno()), digest(staged, cancelled=cancelled)), "fields": written_fields}
                    stage_identity = os.fstat(staged.fileno())
                if before_commit:
                    before_commit()
                check_cancel(cancelled)
                with self.parent(path) as (current_parent, _):
                    if (os.fstat(parent).st_dev, os.fstat(parent).st_ino) != (os.fstat(current_parent).st_dev, os.fstat(current_parent).st_ino):
                        raise ServiceError("conflict", "The file's directory moved during the edit.", 409)
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if identity(current) != identity(original) or stamp(os.fstat(source.fileno()), digest(source, cancelled=cancelled)) != expected:
                    raise ServiceError("conflict", "The file changed before replacement; the edit was discarded.", 409)
                if dry_run:
                    result = {"path": path, "status": "validated", "before": expected, "after": written}
                    persist_success(result)
                    return result
                # A hard link preserves the original inode, including ACLs and attributes, for rollback.
                os.link(name, backup_name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
                backup = True
                linked = os.stat(backup_name, dir_fd=parent, follow_symlinks=False)
                if (linked.st_dev, linked.st_ino) != (original.st_dev, original.st_ino):
                    raise ServiceError("conflict", "The source was replaced during the edit.", 409)
                os.fsync(parent)
                check_cancel(cancelled)
                os.replace(stage_name, name, src_dir_fd=parent, dst_dir_fd=parent)
                replaced = True
                os.fsync(parent)
                if after_replace:
                    after_replace()
                if stamp(os.fstat(source.fileno()), digest(source)) != expected:
                    raise ServiceError("conflict", "Another writer changed the original during replacement.", 409)
                with open(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent), "rb", closefd=True) as committed:
                    if os.fstat(committed.fileno()).st_ino != stage_identity.st_ino or digest(committed) != written["sha256"]:
                        raise ServiceError("verification_failed", "The replacement could not be verified.", 500)
                # Finish acknowledgement even if cancelled now: this file has already been replaced.
                result = {"path": path, "status": "succeeded", "before": expected, "after": written}
                try:
                    persist_success(result)
                    durable = True
                except Exception as error:
                    # Keep both files if the status could not be made durable; never silently retry.
                    raise ServiceError("recovery_required", "The file may be updated; a recovery copy was retained. Check this job before retrying.", 500) from error
                # A failed recovery-copy cleanup must not turn an acknowledged successful edit into a retry.
                with contextlib.suppress(OSError):
                    os.unlink(backup_name, dir_fd=parent)
                    backup = False
                    os.fsync(parent)
                return result
            except Exception as error:
                if replaced and not durable and not (isinstance(error, ServiceError) and error.code == "recovery_required"):
                    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) == (stage_identity.st_dev, stage_identity.st_ino):
                        os.replace(backup_name, name, src_dir_fd=parent, dst_dir_fd=parent)
                        backup, replaced = False, False
                        os.fsync(parent)
                    else:
                        raise ServiceError("recovery_required", "Another writer changed the replacement; the original recovery copy was retained.", 500) from error
                raise
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(stage_name, dir_fd=parent)
                if backup and not replaced:
                    os.unlink(backup_name, dir_fd=parent)
