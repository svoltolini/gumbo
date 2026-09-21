# Isolated SMB read fixture

This fixture serves only generated data on loopback. It never mounts a NAS or reads real account details. Music shares are read-only. The encrypted server also has a disposable `resume-tests` share inside its container: resume and deletion tests create their own generated files there to verify concurrent-write exclusion, changed-file recovery and reviewed exact-file deletion. The reply-loss test starts an ephemeral loopback relay with a fixed destination at this disposable share; it drops a real encrypted reply without inspecting its contents. It has no writable host mount. The test-only password is `fixture-only`.

From the repository root, with Docker Desktop running:

```sh
python3 Tools/SMBReadFixture/prepare.py
docker compose -f Tools/SMBReadFixture/compose.yaml up --build -d
GUMBO_SMB_LOCAL_FIXTURE=1 swift test --package-path Packages/GumboCore --filter SMB
docker compose -f Tools/SMBReadFixture/compose.yaml down
```

Ports 14450, 14451 and 14452 bind only to `127.0.0.1`. They provide encrypted SMB3, signed SMB2.1 without encryption, and a server which maps unknown users to guest. Tests must authenticate with the intended policy or reject the session; they never fall back to guest or SMB1.

The integration tests are skipped unless explicitly enabled. Their endpoints are hard-coded loopback addresses, not environment-configurable hosts.
