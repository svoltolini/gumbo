# Native SMB receive regression tests

From the repository root on macOS:

```sh
Packages/GumboSMB/Tests/run-security-tests.sh
```

An optional first argument selects the scratch build directory. The script builds the vendored dynamic package, links the C fixture against that exact build, and returns a nonzero status if any assertion fails. It uses local socket pairs only; it does not connect to a NAS or access credentials.

`receive-security.c` drives the real SMB socket receive state machine with queued requests and encoded reply bytes. It covers:

- Unsigned, signed and encrypted replies whose command differs from the queued request; these must fail before reply-body decoding.
- Valid signed/encrypted READ replies and tampered signatures/encryption tags.
- Interim `STATUS_PENDING`, including header-only replies; encryption-required sessions must reject plaintext interim replies.
- Legitimate NEGOTIATE/SESSION_SETUP exchanges before a session key exists.
- Signed/encrypted unsolicited oplock notifications and rejection of unsigned notifications.

The fixture uses deterministic synthetic encryption material exclusively within one local process. It is not production connection code. Samba integration tests and physical NAS/device acceptance remain separate checks.
