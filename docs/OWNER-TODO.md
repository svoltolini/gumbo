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

## 6. Items added by the P3 batch

_Filled in when the P3 batch is merged._
