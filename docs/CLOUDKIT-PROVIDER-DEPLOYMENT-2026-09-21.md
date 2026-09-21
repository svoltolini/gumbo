# Provider connection schema deployment

On 21 September 2026, the optional `Family.providerConnection` field was added as **Bytes** to `iCloud.com.samuelvoltolini.gumbo` and deployed to **Production** through CloudKit Console after the owner restored the Apple session.

The deployment diff contained one additive field. Existing fields, indexes, security roles and grants were unchanged. The field stores versioned, non-secret provider configuration; passwords remain in their separate credential stores.

CloudKit reported **Changes Deployed — The schema is deployed to Production**. The Production environment was then selected and `Family` reopened. It showed 15 fields including `providerConnection BYTES`, with no single-field indexes. This read-back verifies deployment rather than merely recording that Deploy was clicked. No user records were queried or changed.

This completes the production-schema prerequisite for issues #194 and #198. It does not prove cross-device delivery, personal iCloud Keychain arrival, or owner/member revocation on separate Apple Accounts; those remain acceptance checks against the provider-aware app build.
