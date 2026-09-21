# Connect a music library

The development build offers Synology, HTTPS WebDAV and SMB connections. A provider option is not a promise that every NAS model or firmware has been tested. See [the compatibility evidence](PROVIDER-COMPATIBILITY.md) for the exact configurations exercised so far.

Your music remains on the NAS or in downloads on your Apple devices. Gumbo does not require a Gumbo account or upload the library to a Gumbo service. Your NAS sign-in is still needed. Start with an account that can read the music folder; administrator access is unnecessary for listening.

## Synology

Keep the existing Synology option for DSM File Station. Enter the DSM HTTPS address and port used by your NAS. The certificate must be trusted and match the hostname: entering an IP address instead can cause a certificate error even when the server is reachable. The normal setup continues through account, music folder and library scan.

Changing to WebDAV or SMB creates a separate library identity, even if it reaches the same physical files. Gumbo does not silently move favourites, playlists or downloads between protocols, account names, shares or endpoint aliases. Existing Synology connections keep their existing identity.

## HTTPS WebDAV

1. Enable the NAS's WebDAV service and grant the listening account access to the music folder. Use its HTTPS endpoint with a certificate trusted by your Apple devices. The ordinary administration website is often a different endpoint.
2. In Gumbo, choose **WebDAV** and enter the complete address, including its port and base path if required, for example `https://nas.example:5006/music/`. This is an illustrative address; use the one your NAS actually exposes. Do not put a username/password in the URL.
3. Enter the WebDAV account and password. Choose the music folder shown by the connection, then let Gumbo scan it. The configured endpoint is the boundary of the browsable library.
4. Try a song, seek near its end, then download a small album and play it offline. The server must return byte ranges for playback and metadata reading, as well as complete WebDAV folder listings. A successful password check alone does not establish those capabilities.

HTTP WebDAV, invalid/self-signed certificates without device trust, redirects to another endpoint, browser-only sign-in pages and servers without byte ranges are refused. If an address redirects, enter its final HTTPS WebDAV address directly. The current adapter sends Basic authentication over HTTPS; do not assume a Digest-only or interactive SSO server is compatible.

For QNAP QTS 5.2, the vendor documents WebDAV under **Control Panel → Applications → Web Server → WebDAV**, with HTTPS and permission options. Verify the steps for your installed firmware; this does not certify a QuTS hero or QNAP model. [QNAP's WebDAV instructions](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/configuring-webdav-settings-CDDF133D.html).

Apple Watch can download selected playlists directly from the HTTPS WebDAV endpoint after the paired iPhone supplies its scoped sign-in. Keep the same endpoint reachable from the Watch's network. [Watch provider details](WATCH-PROVIDERS.md).

## SMB shared folders

1. Enable SMB2/3 on the NAS, grant a named account read access to the chosen share, and enable SMB3 encryption where available. Guest/anonymous access and SMB1 are unsupported.
2. In Gumbo, choose **SMB**, enter a server address such as `smb://nas.local`, and enter the shared-folder name separately, for example `Music`. Do not append a share or password to the server address. A custom port is accepted when needed.
3. Enter the account/password. If your server requires a domain, supply it in the domain field. For an ordinary local NAS account, leave the domain empty. Do not supply the domain twice.
4. Keep encrypted SMB3 selected. If the server only supports SMB2, the explicitly selected signed mode requires authenticated signing but does not encrypt file contents. Use a trusted local/private network for that mode. Gumbo will not silently downgrade after a failed login.
5. Select the music folder, scan, and check playback, seeking and downloads. SMB transfer work depends on the app's permitted running time; suspension or network loss may require a retry. Already completed offline songs stay available.

For remote access, reach SMB over your private network or VPN. This guide does not require publishing a file-sharing port to the internet. Network reachability and authentication are separate: a VPN connection alone does not provide the correct NAS account/share permission.

There is **no direct SMB socket connection on Apple Watch**. Keep Gumbo open on a reachable iPhone while it prepares the selected songs. The prepared audio is transferred to Watch for offline listening; the SMB account and password stay on the phone. Already prepared WatchConnectivity transfers may continue after the iPhone app backgrounds. [Apple's watchOS networking restrictions](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos).

## Optional metadata editing

Normal listening does not need another service. The initial WebDAV and SMB adapters are read-only, so they cannot by themselves rename an album, rewrite tags or delete originals from your NAS.

The [optional Gumbo metadata helper](../Tools/GumboTagService/README.md) can edit album, album-artist and genre tags on a server where you deliberately install and configure it. It uses a separate HTTPS address/token and an explicit mapping to the selected library folder. It is under validation and does not install itself, provision NAS accounts or delete files. Read its setup/recovery instructions before enabling it; broad NAS compatibility or deployment is not established by the local fixture tests.

## Sign-in and family sync

The connection includes its provider, endpoint/base path or share, domain and account. Personal password sync is an explicit iCloud Keychain choice on supported devices, distinct from Family Access. Family users of a generic provider need a restricted account prepared by the NAS owner; Gumbo does not use Synology's account-administration calls on WebDAV/SMB servers. Update Gumbo on every participating device before using a new provider. An older client will not interpret generic credentials as a DSM sign-in.

## When a connection fails

| Symptom | Check |
| --- | --- |
| Certificate error | Use the certificate's exact hostname, trusted certificate chain and correct HTTPS port. Do not disable verification. |
| Sign-in rejected | Confirm the service-specific account, password and share permission. A web administration login is not proof of WebDAV/SMB access. |
| Folder missing or scan incomplete | Check the selected base path/share and read permission on all subfolders. Gumbo retains the previous catalogue when enumeration fails. |
| Playback refuses ranges | Enable a server endpoint that supports standard byte-range responses; a plain HTML/download portal is insufficient. |
| SMB security error | Enable supported signing/encryption on the server. Encrypted mode requires SMB3; there is no SMB1 or guest fallback. |
| Watch asks for iPhone | For SMB, open Gumbo on the paired iPhone and keep it open while preparing songs. Retry interrupted requests. |
| Another device has favourites but no offline audio | Synced library/download membership does not itself transfer every music file. Download on that device, or transfer selected playlists to Watch. |

For a useful compatibility report, record the NAS/server model, firmware/server version, selected protocol, authentication type, encryption mode, Apple device/OS, whether you were local or on a VPN, and the action/error. Never include passwords, helper tokens, session IDs or private keys.
