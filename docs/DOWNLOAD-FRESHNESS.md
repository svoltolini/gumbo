# Download freshness after NAS edits

Completed downloads retain the file identity known when they were requested: path, positive byte size, provider modification time/version and enriched embedded album/album-artist/genre tags. A difference in a fact known on both sides marks the saved copy outdated. This detects same-size tag edits; presentation-only album regrouping does not invalidate audio.

The main apps keep the old file and album/playlist memberships until an explicit download retry replaces it. Stale files are excluded from playable local URLs and completed-download counts. Reconciliation does not silently adopt them as orphan files or start a new download. A successful replacement retains every owner and removes the previous file only after persisting the new manifest. Failed replacement retains the previous file. A transfer that finishes after a known catalogue change is rejected.

Downloads summaries observe catalogue content revisions as well as membership changes. The UI offers to download missing songs and update changed files; it no longer describes every incomplete download as an iCloud restoration.

## Watch

Watch catalogues, jobs and manifests carry the same optional file revision. Updated catalogues make outdated copies unavailable and prune their local cache files while retaining desired playlist membership. Stale direct-download completions and iPhone relay requests cannot publish the old revision. See [Watch providers](WATCH-PROVIDERS.md) for the separate authorization and delivery boundaries.

## Compatibility and limits

- Old jobs, records and Watch catalogues still decode. Existing files without revision evidence adopt a first known baseline; that migration cannot certify historical bytes against the NAS. Existing orphan-file adoption also cannot prove freshness beyond its size/audio checks.
- Revision evidence is not a content checksum or an authorization grant. Providers that omit or fail to change their validators can conceal changes, especially when size and known embedded tags are unchanged.
- Another device learns about an edit on a subsequent successful scan/sync. This is not instantaneous cross-device invalidation. Older app versions retain their older behavior.
- This change does not validate physical Watch delivery, authenticated background relaunch or a real-NAS metadata-helper installation.

## Validation — 22 September 2026

- All **734 core tests in 57 suites passed**, including the isolated loopback Samba fixtures. Fixture services were stopped afterwards.
- Focused regressions cover same-size version/time/genre changes, restart persistence, explicit retry, shared membership, failed replacement, late completion, live-attempt replacement, legacy decoding and Watch relay/manifest rejection.
- Signed Release macOS, iOS with Watch/widget extensions, and tvOS builds passed. Strict signature verification passed for the prepared applications.
- Development Mac build **202609221515** launched from `/Applications/Gumbo.app` with the existing library and profile retained. Downloads showed three existing memberships needing files, the explanatory update text and per-album Retry actions. No download was triggered by this UI check.
- No real NAS file or tag was changed for this validation. Physical iPhone, Watch and other provider acceptance remain tracked separately.
