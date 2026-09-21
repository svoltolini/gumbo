# Personal NAS sign-in sync

GitHub issue: [#181](https://github.com/svoltolini/gumbo/issues/181).

Gumbo can optionally save a personal NAS password in iCloud Keychain for iPhone, iPad and Mac on the same Apple Account. The NAS account, server address and selected folder already travel in the owner's existing CloudKit setup record. Personal passwords never enter that record or Family Sharing.

## Behavior

- Existing users opt in once in Settings > Music Server > Sync sign-in with iCloud Keychain. New or returning sign-ins offer the same choice beneath Remember me. No existing device-only password is silently uploaded.
- Use This Library checks the verified owner's exact saved NAS origin and account for a synchronized password. If available, it signs in and reuses the saved music folder. Invited family members retain the separate Family Access path.
- Missing or delayed Keychain items leave manual sign-in available. Apple Account and Passwords & Keychain must be enabled on the relevant devices. Saving an item locally does not prove that iCloud has delivered it elsewhere.
- A two-factor challenge retains the password only for the pending sign-in and asks for the verification code. Rejected passwords remain editable. Canceled and superseded requests cannot install a session or publish credentials.
- Opting out removes the synchronized copy while preserving local remembered sign-ins. Signing out removes this device's remembered credentials, without deleting the synchronized copy. Remember me disabled prevents local restoration even if cloud removal fails; removal errors remain visible.
- Corrected passwords and verified Family Access rotations supersede old synchronized values. A failed cloud update keeps the newly verified local password usable and reports the problem.
- tvOS does not synchronize third-party Keychain items. Apple TV retains its existing setup and Family Access behavior. Watch setup remains paired with iPhone.

## Storage and signing

`SyncedServerCredentialStore` uses a separate generic-password service, a structured key containing normalized scheme/host/effective port plus case-sensitive NAS account, `kSecAttrSynchronizable`, and the Data Protection Keychain. Both signed iOS and Mac applications use their existing app-ID access group; widgets and Watch do not receive access to this new store. Local passwords, Family Access provisioning credentials, and Watch credentials keep their existing storage.

Security-operation tests inject every Keychain operation and do not read or modify real credentials. State-flow tests inject NAS login, CloudKit inputs and persistence. Mac view captures use isolated fixtures. Real iPhone-to-Mac Keychain delivery remains a device acceptance check tracked in [#123](https://github.com/svoltolini/gumbo/issues/123).

## Device acceptance

1. Install the updated build on iPhone and Mac, both using the same Apple Account with Passwords & Keychain enabled.
2. On the connected iPhone, enable Sync sign-in with iCloud Keychain in Music Server settings.
3. On Mac, return to the saved-library card and choose Use This Library. Verify the account and folder match the iPhone and the library opens without re-entering the password (apart from any NAS verification code).
4. Check unavailable Keychain, delayed arrival, changed NAS password, cancellation and opt-out. Confirm Family Sharing never exposes the personal password.

References: [Apple synchronizable Keychain items](https://developer.apple.com/documentation/security/ksecattrsynchronizable), [Keychain access groups](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
