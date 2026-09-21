# Native Mac genre-write fixture

Hosts the production `GenreEditorSheet`, `LibraryStore`, `MetadataWriter` and Swift tag writer in an independent sandboxed app. It copies generated five-second MP3/FLAC/AAC-M4A files into its own container and uses a local `WritableRemoteDrive` fixture. It has no server address, network entitlement, Keychain access or CloudKit instance. The fixture refuses to start unless its application-support path belongs to its separate container.

This checks UI → real tag rewriting → catalogue refresh, not Synology/WebDAV/SMB transport or the optional remote helper. Reads have a deliberate 350 ms delay so progress can be observed; this is not a performance measurement. Do not disable sandbox signing: the production cache uses the process's application-support directory.

## Build and exercise

Requires Apple Silicon, Xcode and the development-only `imageio-ffmpeg==0.6.0` Python package. From the repository root:

```sh
xcodebuild -project Gumbo.xcodeproj -scheme GumboMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/gumbo-genre-fixture-derived build
python3 -m venv /tmp/gumbo-genre-fixture-tools
/tmp/gumbo-genre-fixture-tools/bin/pip install 'imageio-ffmpeg==0.6.0'
/tmp/gumbo-genre-fixture-tools/bin/python Tools/MacGenreFixture/build.py \
  /tmp/gumbo-genre-fixture-derived /tmp/gumbo-genre-ui-output
```

Choose a new output directory on subsequent builds; the script refuses to remove an existing one. Open the generated `GumboGenreWriteFixture.app`, change Ambient to Jazz in the focused field, and click Done. The sheet should finish and dismiss, and the host window should show `Library genres: Jazz`, three songs and an advancing UI heartbeat. The Edit Genre button reopens the real editor for further interaction. The fixture closes after six minutes.

Its separate bundle ID is `com.samuelvoltolini.gumbo.genre-write-fixture`. The container's `Data/Library/Application Support/latest-run.txt` records the generated run directory. That directory contains the resulting `music` files, isolated profiles and `saved-catalogue.json`. The ordinary catalogue cache stays inside the same fixture container. Originals remain in the fixture bundle's `Contents/Resources/FixtureMusic` for comparison; nothing from the user's library is copied.

## Observed on 2026-09-21

On macOS 27.0 with Xcode 27.0, the native Debug app build and sandboxed harness build passed. The actual focused-field → Jazz → Done interaction dismissed the sheet and displayed Jazz for all three songs while the UI remained responsive. Each resulting MP3, FLAC and M4A had a Jazz genre tag. Independent parsing with the helper's audio/tag signature functions confirmed identical encoded audio and unrelated tags before/after. The saved catalogue contained one album, three tracks and Jazz; no hidden staging or backup files remained.

This extends the earlier [genre UI regression evidence](../../docs/PLAYBACK-GENRE-SIRI-2026-09-21.md) beyond a fake read-only failure to successful generated-file saves. It does not reproduce or establish the cause of the user's original process exit, and does not close physical-device or live-NAS acceptance in #199/#201.
