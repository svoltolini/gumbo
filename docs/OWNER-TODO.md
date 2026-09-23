# Owner to-do before the next release

These are things that must be done by hand after the audit fixes (P1 #312, P2 #313, P3). Claude can't do them because they need Xcode, an Apple developer account, the CloudKit Console or the NAS. Work through them in order and tick each box.

## 1. Build and test in Xcode (required)

None of the audit fixes have been compiled. The cloud environment has no Apple SDK, so the Swift changes were only syntax-checked.

- [ ] Open `Gumbo.xcodeproj` in Xcode 26, select each scheme (Gumbo iOS, GumboMac, GumboTV, GumboWatch, GumboWidgets) and build. Fix or report any compile errors.
- [ ] Run the package tests: `cd Packages/GumboCore && swift test`, or use Product > Test on the GumboCore scheme. The new test files are:
  - `AppFlowTests`
  - `WatchDownloadStatusTests`
  - `IndexingRecoveryTests`
  - the added cases in `PlaybackRecoveryTests` and `CloudReliabilityTests`
- [ ] Run the UI tests (`GumboUITests`) on an iPhone simulator.

## 2. CloudKit Production schema (required before TestFlight or the App Store)

Without this step, every Profile upload from the new build is rejected in Production. The full details are in [CLOUDKIT-PIN-VERIFIER-DEPLOYMENT.md](CLOUDKIT-PIN-VERIFIER-DEPLOYMENT.md).

- [ ] Run a **development** build on a device. Set or re-enter a profile PIN, then let it sync.
- [ ] In the CloudKit Console, open container `iCloud.com.samuelvoltolini.gumbo` and switch to the Development environment. Open the `Profile` record type and check that `pinVerifierSalt` and `pinVerifierHash` exist as **encrypted** String fields.
- [ ] Click **Deploy Schema Changes to Production**. The diff should contain only those two fields.
- [ ] Switch to Production and check that both fields are listed as encrypted. Note the date in the deployment doc.

## 3. Metadata helper on the NAS (required if you use tag editing or album deletion)

`Tools/GumboTagService` changed: errors now map by errno, a failed rollback now reports `recovery_required`, and P3 adds further fixes.

- [ ] Rebuild and redeploy the helper container on the NAS. From `Tools/GumboTagService`, run `docker compose build && docker compose up -d`, or use the method from [NAS-SETUP.md](NAS-SETUP.md).
- [ ] In the app, open Settings and check that the helper shows as connected. Then try one tag edit.

## 4. Update every device in the family together

- [ ] Install the new build on every iPhone, iPad, Mac, Apple TV and Apple Watch that uses the family library. Older versions see profiles with a PIN as locked once any updated device saves them.

## 5. Behaviour changes worth checking on a device

- With shuffle on, **Play** starts at a random song.
- After a song fails to play, or at the end of the queue, **Next** and **Previous** load the song paused.
- After you choose a different music folder, downloads from the old folder show as unused storage in Settings > Storage.
- A wrong PIN is free four times, then the keypad waits 30 s, 1 min, 5 min, 15 min, then 1 h.
- After relaunching the iPhone app, the Watch keeps its sign-in. It is no longer signed out on every relaunch.

## 6. Upload the new build to TestFlight (same version 1.0, new build number)

The build number is now **1.0 (202609231100)** in `project.yml` and the Xcode project, for all five targets. The last build testers received was 202609211143. `scripts/check-release-versions.py project.yml` confirms the targets agree. Complete steps 1 to 3 first. If you upload more than once, raise `CURRENT_PROJECT_VERSION` again, because App Store Connect refuses a build number it has already seen.

- [ ] In Xcode, choose the **Any iOS Device** destination, then Product > Archive. Repeat for **GumboMac** (My Mac destination) and **GumboTV** (Any tvOS Device). All three are in external TestFlight testing. The Watch app and the widgets are embedded in the iOS archive.
- [ ] In the Organizer, choose Distribute App > App Store Connect > Upload.
- [ ] Wait for App Store Connect to finish processing the build (about 5 to 30 minutes). Answer the export-compliance question the same way as for the last build.
- [ ] In App Store Connect, open TestFlight and add the build to the internal group, then to each external tester group. Internal testers get it straight away. External testers usually get it without a new Beta App Review, because version 1.0 was already approved. Apple can still review any build, though, so if it shows "Waiting for Review", it just needs time.
- [ ] Fill in "What to Test" with a short summary of the audit fixes.

## 7. Checks on a real device after the P3 batch

Apple's frameworks behave in ways the simulator and the code alone can't confirm. Check these on a device:

- [ ] **Local Network denied (#278).** In Settings > Privacy & Security > Local Network, turn Gumbo off, then open server discovery. It should stop spinning and show "Allow Local Network access" with an Open Settings button. On the Mac, the Privacy Settings link should open System Settings.
- [ ] **Watch interruptions (#267).** Play on the Watch, then take or decline a call. Playback should pause, then resume after the call if you didn't touch anything. Disconnect the headphones: playback should pause.
- [ ] **Watch Resume (#267).** Play, pause, then Resume. It should play without a delay. The headphone picker may appear, as it does on the first Play.
- [ ] **Up Next on iPhone (#311).** Open Now Playing, tap the list button between AirPlay and Repeat, then tap a later song. It should jump to that song.
- [ ] **PIN keypad (#281).** On a small iPhone or at a large text size, open a PIN-locked profile. The keypad should scroll instead of being cut off. Check that Apple TV focus still works on the PIN screen.
- [ ] **Find Missing Genres (#276).** Start a lookup, switch tabs, then come back. The lookup should still be running.
- [ ] **CarPlay (#260).** There should be four tabs: Library, Playlists, Albums, Artists. On a large library, Albums and Artists should be grouped A to Z.
- [ ] **Widgets (#264).** Lock the profile or leave no profile open. The widgets should show a lock and "Open Gumbo to show your music.", not "empty".
- [ ] **Mac menus (#295).** ⌘1 to ⌘7 should match the sidebar order. The Shuffle and Repeat menu items should show a checkmark for the current state.

## 8. Other changes you might notice

- Metadata helper: past 8 simultaneous requests, it now answers "busy" instead of dropping the connection.
- Synology: a folder whose listing keeps timing out is now counted as failed for that scan instead of losing its sizes and dates.
- On first launch after the update, albums briefly show plain colours until their saved palettes load.
- Artists whose names differ only in capitals or accents are merged under the most common spelling.
- Library shuffle picks change once after updating. After that they stay the same all day and change at local midnight.
- iCloud sync now retries by itself after network errors, every few minutes at most, while the app is open.
- The website's `/privacy` link fix goes live automatically when `main` deploys on Vercel.
