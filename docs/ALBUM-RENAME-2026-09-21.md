# Album title edits and release identity

Tracked in #178. A title edit previously changed only the file's ALBUM tag. Once that title no longer matched its physical folder, grouping used each track's ALBUMARTIST tag separately. Guest credits copied into those tags could therefore turn one album into several entries with the same new title and cover.

An explicit album rename now saves the album's displayed release artist together with the title. MP3 uses TPE2, MPEG-4 uses aART, and FLAC uses ALBUMARTIST (keeping an existing ALBUM ARTIST alias consistent). The existing album identity is retained, including Various Artists for a compilation. Unknown Artist is not written as real metadata. Song ARTIST credits, audio bytes, artwork, genre and disc markers remain intact. The rewritten release artist is read back and verified before the original file can be replaced.

Files that fail a write retain their old title and remain listed in the per-file report. Retrying against files already changed by another device updates stale local metadata without another upload.

## Previously split albums

A library refresh can repair a cached split without changing NAS files when the title is a shortened whole-word prefix of the physical release-folder name (at least two words), guest credits share a leading artist, that artist also has a standalone credit, and there are no conflicting disc/track positions. For example, the fixture “Muddy Days, Drunken Nights” → “Muddy Days” coalesces under Jawga Sparxx while keeping every guest credit. Distinct positions are only an extra conflict check, because the indexer can infer missing numbers from filenames.

Generic mixed folders, different leading artists, different collaborations without a standalone lead, overlapping positions and ambiguous names remain separate. Shared title or a shared guest alone does not authorize merging. The reported device's exact folder/tags have not been retrieved, so this fixture demonstrates the reported failure pattern rather than proving that specific library's recovery. Future explicit renames do not depend on folder-name matching: the corrected file tags establish the release on a fresh scan by another device.

## Verification

- Targeted Release suite: 68 tests in 5 suites passed.
- Complete GumboCore Release suite: 477 tests in 28 suites passed.
- Format coverage: ID3v2.3/v2.4 MP3; MPEG-4 m4a/mp4/aac/alac extensions, including new metadata containers and preserved audio chunk offsets; FLAC existing/new comment blocks and legacy aliases.
- End-to-end in-memory drive: rename an album with guest credits to an unrelated new title, inspect rewritten source tags and audio, rebuild with no cache, and retry from a stale cache. Also covers a Various Artists compilation.
- Existing partial-write, cancellation, authorization and concurrent-file replacement tests remain passing.

All source-write tests used temporary local files and an in-memory drive. No user's NAS files were changed. Platform archive and physical-device acceptance are separate release checks.
