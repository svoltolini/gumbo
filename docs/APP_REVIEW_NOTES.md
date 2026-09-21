# App Review notes for Gumbo Music

This document provides App Store Review with the information needed to evaluate Gumbo Music.

## What Gumbo does

Gumbo Music streams and downloads music from a personal Synology NAS (Network Attached Storage). It is not a music-streaming service with its own catalogue—users supply their own music files stored on their own NAS hardware.

## Testing without a NAS

Gumbo includes a built-in **sample library** with 12 demonstration albums containing simulated track metadata. This allows full UI and navigation evaluation without real NAS hardware.

### Enabling the sample library

1. Launch a fresh installation on iPhone, iPad, Mac or Apple TV.
2. On Welcome, choose **Explore Sample Library**. On Apple Watch, choose the same button below the phone-sync instructions.
3. Browse the demonstration albums and playlists. No NAS, login or developer launch arguments are required.

On Apple Watch the sample supports browsing only; playback requires downloaded audio. Phone, Mac and TV sample playback is simulated.

**Note:** The sample library simulates playback (progress bar, time display, transport controls) but does not produce audio output because no actual audio files are bundled. This is expected behavior for review purposes.

### What can be tested with the sample library

| Feature | Testable |
|---------|----------|
| Library browsing (albums, artists, genres) | Yes |
| Search | Yes |
| Playlists (view, create, edit) | Yes |
| Simulated playback controls | Yes |
| Profile creation and switching | Yes |
| Settings and preferences | Yes |
| Widget configuration | Yes |
| CarPlay interface | Yes (simulator) |
| Watch app navigation | Yes |
| Audio output | No (no bundled audio) |
| Real downloads | No (requires NAS) |

## Testing with real NAS hardware

If App Review has access to a Synology NAS or wishes to test full functionality:

1. **NAS requirement:** Synology DiskStation running DSM 7.x or later with File Station enabled
2. **Network:** The review device and NAS must be on the same local network, or accessible via Tailscale
3. **Credentials:** A standard DSM user account with read access to the music folder

The owner can provide temporary demo NAS credentials upon request. Contact information is in App Store Connect.

## Platform-specific notes

### iOS/iPadOS
- Standard library navigation and playback
- Widgets: Now Playing and Recently Played
- Live Activities track downloads; actual download verification requires a NAS

### macOS
- Native Mac app (not iPad-on-Mac)
- Standard window management and keyboard shortcuts

### tvOS
- Focus-based navigation with Apple TV remote
- Top Shelf uses the supplied Gumbo banner artwork

### watchOS
- Companion app for the paired iPhone
- Can download playlists for offline Watch playback (requires real NAS)
- Sample library mode shows playlists without transfer capability

### CarPlay
- Audio playback interface (requires CarPlay-capable vehicle or simulator)
- Approved CarPlay audio entitlement is present

## Capabilities and entitlements

| Capability | Purpose |
|------------|---------|
| CloudKit | Sync profiles, favorites, and playlists across devices via user's iCloud |
| App Groups | Share data between main app and widgets |
| CarPlay Audio | Display playback controls on vehicle screen |
| Background Audio | Continue playback when app is backgrounded |
| Background Processing | Complete download and indexing tasks |
| Local Network | Discover and connect to NAS on LAN |
| Bonjour | Discover NAS services via mDNS |

## Privacy

- No analytics SDK or advertising framework
- No data sent to developer servers
- CloudKit data stored in user's private iCloud container
- Remembered NAS credentials stored in Keychain; optional iCloud Keychain sync across the same Apple Account on iPhone, iPad and Mac, off by default and separate from Family Access
- See in-app Privacy Details for full disclosure

## Export compliance

The provider implementation adds dynamically linked libsmb2 on iOS, macOS and tvOS. It includes third-party cryptographic code for standard SMB signing/authentication/encryption; the prior statement that all encryption comes from Apple's operating system no longer describes these builds.

The automatic `ITSAppUsesNonExemptEncryption=false` answer is therefore omitted for these three targets pending the App Store Connect encryption questionnaire and any required documentation. This is an explicit distribution gate, including TestFlight. Do not reuse the earlier build's encryption declaration without reassessing the changed binary. Watch uses Apple HTTPS and WatchConnectivity and does not link libsmb2.

References: [Apple export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance), [encryption documentation requirements](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/), and [SMB dependency/distribution record](SMB-DEPENDENCY.md). This engineering record does not make an export-law determination on the owner's behalf.

## Contact

For review questions or temporary NAS access, contact the developer through App Store Connect or the support URL provided in app metadata.
