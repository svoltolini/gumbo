# PIN verifier schema deployment (#257)

**Status: not yet deployed to Production.** Deploy before any build containing the #257 change reaches TestFlight or the App Store.

## What changed

Profile PINs used to travel as plain `Profile.pinSalt` and `Profile.pinHash` String fields: one salted SHA-256 that anyone who joined the family with the invitation link could read and brute-force offline in milliseconds. The app now:

- derives new and re-entered PINs with PBKDF2-HMAC-SHA256 (200,000 iterations, per-profile salt), stored as `pbkdf2-sha256$<iterations>$<key>` in the same local `hash` field;
- sends the verifier in two new **encrypted** String fields, `Profile.pinVerifierSalt` and `Profile.pinVerifierHash` (`record.encryptedValues`), like `Family.familyPassword`;
- writes the marker `encrypted` into the old plain `pinSalt` and `pinHash` fields whenever a PIN is set, and clears all four when it is removed;
- limits wrong PINs per profile on each device: four are free, then the keypad waits 30 seconds, 1, 5 and 15 minutes, then an hour after each further wrong PIN. The count is kept in the device's UserDefaults and starts again after the right PIN, Face ID or Touch ID, a new PIN, or the profile's removal.

An existing plain field cannot become encrypted, so these are new fields rather than a change to the old ones.

## Production schema step

CloudKit creates the two fields by itself only in the **Development** environment, the first time a development build saves a profile with a PIN. In **Production** a save that names an undeployed field is rejected, so every Profile upload from the new build would fail until the schema is deployed.

1. Run a development build, set or re-enter a profile PIN, and let it sync.
2. In CloudKit Console for `iCloud.com.samuelvoltolini.gumbo`, Development, open the `Profile` record type and confirm `pinVerifierSalt` and `pinVerifierHash` are listed as **encrypted** String fields.
3. Deploy the schema to Production. The diff should contain only these two additive fields.
4. Select Production, reopen `Profile` and confirm both fields are listed as encrypted. Record the read-back here, as was done for [`Family.providerConnection`](CLOUDKIT-PROVIDER-DEPLOYMENT-2026-09-21.md).

Encrypted fields cannot be indexed or queried, and nothing queries them.

## Compatibility

- **Records from earlier versions** keep working. When the plain fields hold a real salt and hash (not the marker), they are read as before, and the old SHA-256 PIN still opens the profile. On its first right entry the device derives it again with PBKDF2 under the same salt and uploads it. Other devices treat this as the same PIN: an open profile stays open and Face ID stays enrolled.
- **Earlier app versions reading new records** see the marker, so they still show the profile as locked, but no PIN opens it there. Update every device in the family. A PIN set or removed by an earlier version is written to the plain fields, and the new version then uses that PIN over any encrypted verifier left from before.
- If a record has the marker but its encrypted fields can't be read, the profile stays locked until someone who can manage it sets a new PIN.

## What this does and doesn't protect

Encrypted values are end-to-end encrypted with keys shared only among the zone's participants, so Apple and anyone outside the family can't read the verifier. **Participants can still read it**, and anyone holding the invitation link can join. PBKDF2 makes each guess against a four-digit PIN about 200,000 times more expensive, but 10,000 guesses stay feasible offline for a determined attacker with the record. The PIN keeps family members on a shared device out of each other's profiles. It isn't a secret that holds up against someone who has joined the family.
