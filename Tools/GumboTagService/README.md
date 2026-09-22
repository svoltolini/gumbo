# Gumbo metadata helper

An **optional, separately installed** service for editing music tags on the machine that stores the files. Only small JSON requests cross the network; the helper stages and verifies the file locally. Ordinary Gumbo listening does not need this service. No private Synology API is used. The service does not fetch genres or contact an external metadata provider.

This implementation is under validation. Automated fixtures pass; installation on a real NAS, its filesystem/ACL behavior, certificate setup, crash recovery and the complete app integration still require acceptance before deployment claims or issue #201 closure.

## License and separation

**Everything in this directory is GPL-2.0-or-later**, including the helper code and generated test tones. See [COPYING](COPYING). The dependency [Mutagen](https://mutagen.readthedocs.io/en/latest/) is GPL-2.0-or-later; it is installed only in this separate Python service, never linked into an Apple app target. The Swift app talks to a versioned HTTP API. If you distribute a helper image, retain the license notices and provide its corresponding source, including your modifications and the Mutagen source, as required by the GPL. The pinned Mutagen wheel uses its verified SHA-256 digest.

## Scope and safeguards

- Supports MP3, native FLAC, and AAC/ALAC in M4A, up to 2 GiB per file with at most 32 MiB of parsed metadata. Only **album**, **albumArtist**, and **genre** may change. Omitted fields stay unchanged; this baseline does not delete tags. Exact-file deletion is a separate, disabled-by-default capability.
- Requires an explicit bearer token on every endpoint and trusted HTTPS. Requests use relative paths under one mounted music folder. Absolute paths, parent traversal, symbolic links, hard links, reserved recovery paths and non-regular files are refused.
- Runs as the music file owner, with no privilege escalation. The parent folders must be writable. Mixed-owner libraries need an appropriate separate configuration; the helper does not silently change file ownership or bypass permissions.
- Every edit requires the file's size, nanosecond modification time and SHA-256. Source metadata and content are checked again before replacement. Missing-genre edits inspect the actual current tags and leave an existing genre unchanged.
- Writes a private staged copy, changes tags with Mutagen, reads them back, and verifies encoded audio bytes plus unrelated tag values. It preserves permissions, ownership/group and extended attributes. Unsupported or unverifiable files are left alone. The modification time advances by at least one whole second so coarse NAS indexes can notice same-size changes.
- Replaces the source atomically in the same directory, with an original-inode recovery link until the successful result is durable. A verification failure rolls back when the target is still the helper's replacement. If another writer changed it, or acknowledgement cannot be persisted, the helper retains the original recovery copy and reports **unconfirmed**.
- Jobs are serialized. Cancellation is checked between copy/hash chunks, before the atomic replacement and between files. Mutagen's current tag-save call cannot be interrupted mid-call; after replacement the helper finishes verification and records the result, even if cancellation arrives. Already completed files stay completed.

File locks are advisory. Stop other tag editors/importers while a helper job runs: no ordinary rename-based editor can guarantee cooperation from another program holding and writing an old file descriptor. This helper detects observed changes and refuses or rolls back, but cannot coordinate with an unrelated writer that ignores locks. Keep regular NAS backups; recovery links are an operation safeguard, not a backup system.

## Configure and deploy explicitly

1. Pick exactly the music folder the app uses, and the UID/GID of its owner. Create a separate private state folder owned by that UID/GID. Do not mount the NAS root, Docker socket or other shares.
2. Generate a token file with at least 32 random bytes, for example `python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > token`. Restrict access to its owner. Never put the token into a URL, source control, a public website or logs.
3. Supply a TLS certificate and private key for the helper's hostname. The Apple devices must trust the certificate and its hostname must match the configured address. Certificate verification is never bypassed. Use a private LAN or VPN; don't expose this write service to the public internet.
4. Set the variables below in a local `.env` file (ignored by Git). Paths are on the Docker host. The certificate/key and token must be readable by the configured UID.

```dotenv
GUMBO_UID=1000
GUMBO_GID=1000
GUMBO_MUSIC_DIRECTORY=/srv/music
GUMBO_STATE_DIRECTORY=/srv/gumbo-tags-state
GUMBO_TOKEN_PATH=/srv/gumbo-tags-secrets/token
GUMBO_CERTIFICATE_PATH=/srv/gumbo-tags-secrets/cert.pem
GUMBO_PRIVATE_KEY_PATH=/srv/gumbo-tags-secrets/key.pem
# Defaults to 127.0.0.1. Choose the NAS's private interface explicitly for device access.
GUMBO_LISTEN_IP=192.168.1.10
# Optional. Leave unset/0 to prohibit deletion, even for an authenticated app.
GUMBO_ALLOW_DELETION=0
```

5. Review [compose.yaml](compose.yaml), then run `docker compose build --pull` and `docker compose up -d` from this directory. The image runs with a read-only root filesystem, dropped capabilities, a non-root UID and bounded resources. Only the chosen music folder and private job-state folder are writable mounts. Pin the base-image digest in your deployment if reproducible image rebuilds are required.
6. In Gumbo's advanced metadata settings, associate the helper address, such as `https://nas.example:8443`, with the exact selected library folder. Store its separate token and test the connection before enabling writes. For an app library root `/music` and a file `/music/Artist/Album/01.flac`, the helper receives `Artist/Album/01.flac`. The helper's `/music` mount must refer to that same library folder. **The app never sends arbitrary absolute NAS paths.**

The service has no built-in auto-update, NAS installation, account sharing or discovery. Rotating the token requires restarting it and updating the app's separate helper token. Preserve the state volume across restarts and upgrades so an already used job ID cannot silently execute again.

For development only, `server.py --http-loopback` disables TLS and forces binding to `127.0.0.1`. The shipping Swift client accepts HTTPS only. Tests use isolated loopback fixtures, not a NAS.

## API v1

All responses are JSON with `version: 1`. Authenticate with `Authorization: Bearer <token>`. No redirects, cookies or browser CORS access are used. Request bodies are limited to 256 KiB; one job may contain at most 128 distinct files.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/v1/capabilities` | Supported fields, formats and limits |
| POST | `/v1/files/stat` | `{"path":"Artist/Album/01.flac"}` → `path`, `expected` and actual `fields` |
| POST | `/v1/files/inspect-range` | When enabled: relative path, expected fingerprint, offset and count → matching base64 bytes (at most 1 MiB) |
| POST | `/v1/files/review-delete` | When enabled: relative music path → full-file deletion fingerprint; no mutation |
| PUT | `/v1/jobs/<lowercase-UUID>` | Submit the following request; 202 when newly queued, 200 for the same durable request |
| GET | `/v1/jobs/<lowercase-UUID>` | Read per-file results and overall state |
| POST | `/v1/jobs/<lowercase-UUID>/cancel` | Body `{}`; request cancellation, then keep polling for final outcomes |

```json
{
  "version": 1,
  "dryRun": false,
  "files": [{
    "path": "Artist/Album/01.flac",
    "expected": {
      "size": 123456,
      "mtimeNs": 1790000000000000000,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    "changes": {"genre": "Jazz"},
    "onlyIfGenreMissing": true
  }]
}
```

Use actual values returned by stat, not the illustrative values above. `onlyIfGenreMissing` defaults to false and is accepted only for genre-only edits. Missing means absent/blank, “unknown,” “unknown genre” or “no genre.” `dryRun: true` performs the local staging and verification without replacing the original.

The same job UUID with the same request returns its existing state and never edits again. Reusing it with different data returns `job_conflict`. A lost HTTP acknowledgement must be recovered with **the same ID**; don't invent a new job and repeat a potentially completed operation.

Job states: `queued`, `running`, `completed`, `cancelled`, `partial`, `interrupted`. Per-file states: `pending`, `running`, `succeeded`, `unchanged`, `validated` (dry run), `deleted`, `failed`, `cancelled`, `unconfirmed`. Confirmed tag outcomes carry `before` and `after`; `after` includes current `size`, `mtimeNs`, `sha256` and `fields: {album, albumArtist, genre}`. An unchanged existing genre is returned so the app can correct stale cached metadata without overwriting the file.

## Optional reviewed file deletion

Set `GUMBO_ALLOW_DELETION=1` (or pass `--allow-reviewed-deletion`) only when you want the helper to delete reviewed music files. In the app, explicitly enable **Allow reviewed file deletion** while connecting the helper. Existing configurations stay off. The helper token is not shared with family members; app operations additionally require the current owner profile, source, folder and connection. The token grants the enabled server operations, so do not give it to untrusted clients.

Gumbo uses native reviewed deletion for DSM/SMB. For a read-only provider such as WebDAV, the optional helper can delete an album after the owner reviews its exact song list. The app compares the complete file hash through both connections to catch differing mapped files. Identical copied libraries cannot prove the folder mapping, so the owner must still verify the mount; preparing a deletion review therefore reads music bytes and can take time. This is separate from tag editing, whose file rewrite stays on the NAS. The same helper can authorize reviewed damaged-file cleanup: each inspection range is captured during the full-file hash pass, then returned only if the expected fingerprint matches. Gumbo keeps recent files, unrecognized formats and connection failures; only verified empty files or confirmed MP4 structural damage can be selected. Deletion is never automatic.

The API accepts `{"version":1,"operation":"delete","files":[{"path":"Artist/Album/song.flac","expected":{...}}]}` with actual `expected` values from `/v1/files/review-delete`. No `changes` field is accepted. Supported deletion extensions are the app's audio formats, including empty damaged files; non-music paths, folders, links and files over 2 GiB are refused. A `deleted` result carries `before` and no `after`. A dry run returns `validated` without mutation. Requests and recovery use the same durable job-ID rules as edits. Unconfirmed outcomes stop the batch; remaining files are cancelled.

Deletion reserves a private `.gumbo-tag-<job-id>-<index>.deleting` directory, moves the exact candidate into it, and verifies its inode and fingerprint before unlinking it. A changed candidate or cancellation is restored only if its original path remains absent. Restoration never overwrites a newly created file. If restoration or durable acknowledgement fails, the result is **unconfirmed**; inspect the original path and any `original` file inside the recovery directory. Do not delete that recovery directory automatically. Directory paths remain excluded from the music index. These operations still require other writers to respect locks, as described above.

## Recovery

On restart, a file that was running becomes **unconfirmed** and pending files are cancelled; the helper does not guess whether the last atomic replacement happened or automatically run the job again. Query the original job ID. Inspect the current file and any `.gumbo-tag-<job-id>-<file-index>.backup` alongside it. A backup is the original inode, including its metadata; never delete it merely because a request timed out. Restore only after checking which copy is correct and ensuring no other writer is working on the path. If a successful edit's backup cleanup was interrupted, a recovery copy can remain even though the durable job says succeeded.

Back up the state folder as well as the music. A disk/state-volume error may leave a valid edit whose acknowledgement is unconfirmed; refresh file information and review it before any retry.

## Tests

```sh
python3 -m venv .venv
.venv/bin/pip install --require-hashes -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
```

The tests exercise generated MP3/FLAC/M4A audio, unrelated tags, permissions, dry run, conflict/low-disk rejection, traversal/symlink/hard-link refusal, rollback, missing-genre protection, durable replay/restart, lost acknowledgements, cancellation and authentication. Deletion tests also cover same-size/same-time changes, path replacement, cancellation after capture, recovery without overwriting a new file, empty audio, disabled permissions and durable acknowledgement loss. They do not install a service, access real credentials or contact a NAS.

Run the filesystem tests as a non-root user on Linux, including named-user POSIX ACL and extended-attribute preservation:

```sh
docker build -t gumbo-tag-service:local .
docker build -t gumbo-tag-service:linux-validation tests
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --mount type=volume,dst=/validation \
  gumbo-tag-service:linux-validation
```

The test-only image adds ACL tools; the shipping image is unchanged. The anonymous Docker volume holds only disposable fixtures and is removed with the container. Use this Linux volume rather than a macOS bind mount or tmpfs: those may not support Linux named-user ACLs. All 28 tests passed in this configuration on 22 September 2026, including preservation of extended attributes, UID/GID and ACLs, and rejection of a write to a non-writable parent without modifying the original. These checks establish Docker Linux behavior, not Synology ACL compatibility or real-device acceptance. See [the engineering checkpoint](../../docs/ENGINEERING-CHECK-2026-09-22.md).

The opt-in [transfer benchmark](../../docs/METADATA-HELPER-BENCHMARK-2026-09-21.md) compares actual helper JSON traffic against whole-file download/edit/upload using generated files. On the recorded loopback run the helper saved more than 99.97% of body bytes but took longer; no real-NAS speed claim is made.
