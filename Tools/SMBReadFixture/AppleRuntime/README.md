# Apple runtime probe

An isolated ad-hoc-signed harness for the actual GumboCore/SMB dynamic library. It authenticates only to the generated read-only loopback fixture on port 14450. It checks Unicode listing, stat, bounded range bytes, and a protected copy after seeding a deliberately incorrect local prefix. No Keychain, production app account, NAS or CloudKit state is read.

This is the 2026-09-21 tested harness with only its local output/package paths made portable. It requires the repository's Xcode/Swift toolchain, XcodeGen, and the running [Samba fixture](../README.md).

From the repository root:

```sh
xcodegen generate --spec Tools/SMBReadFixture/AppleRuntime/project.yml
xcodebuild -project Tools/SMBReadFixture/AppleRuntime/SMBRuntimeProof.xcodeproj -scheme SMBProbePhone -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath Tools/SMBReadFixture/AppleRuntime/DerivedData build
xcodebuild -project Tools/SMBReadFixture/AppleRuntime/SMBRuntimeProof.xcodeproj -scheme SMBProbeTV -configuration Release -destination 'generic/platform=tvOS Simulator' -derivedDataPath Tools/SMBReadFixture/AppleRuntime/DerivedData build
xcodebuild -project Tools/SMBReadFixture/AppleRuntime/SMBRuntimeProof.xcodeproj -scheme SMBProbeMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath Tools/SMBReadFixture/AppleRuntime/DerivedData build
```

For each simulator, select an available device ID with `xcrun simctl list devices available` and boot it. Install the matching app in `DerivedData/Build/Products/Release-iphonesimulator/SMBProbePhone.app` or `Release-appletvsimulator/SMBProbeTV.app`, using `xcrun simctl install DEVICE_ID APP_PATH`. Launch with `xcrun simctl launch DEVICE_ID com.samuelvoltolini.gumbo.fixture.smb.phone` (or `.tv`). `xcrun simctl get_app_container DEVICE_ID BUNDLE_ID data` gives the data directory; inspect `Documents/runtime-result.json` there for `"result": "passed"`.

On Mac, launch `Tools/SMBReadFixture/AppleRuntime/DerivedData/Build/Products/Release/SMBProbeMac.app`. Its report is `GumboSMBRuntime-result.json` in the process's temporary directory. For a chosen output path, launch its `Contents/MacOS/SMBProbeMac` executable with `GUMBO_SMB_REPORT_PATH` set to an absolute writable JSON path. The app stays open after writing the report so its result can be inspected; quit only this fixture app afterward.

Verify each built app with `codesign --verify --deep --strict APP_PATH`, verify its embedded `GumboSMB.framework` separately, and check `xcrun otool -L APP_EXECUTABLE` contains `@rpath/GumboSMB.framework`. Stop the fixture containers and these isolated apps when finished. Do not terminate the user's Gumbo app.

These local harness signatures are **ad hoc**, not App Store distribution signatures. The Mac harness does not enable the application sandbox. Passing demonstrates runtime loading and actual SMB I/O on those OS versions, not production app permissions/onboarding, physical-device or NAS-firmware compatibility, background lifecycle acceptance, licensing approval or TestFlight distribution.
