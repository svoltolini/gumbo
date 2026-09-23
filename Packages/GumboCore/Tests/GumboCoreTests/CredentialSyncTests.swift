import Foundation
import Testing
@testable import GumboCore

@MainActor private final class CredentialSyncFixture {
    struct Login {
        let url: URL
        let account: String
        let password: String
        let otp: String?
    }

    let suite = "GumboCredentialSyncTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let library = LibraryStore()
    let saved = ServerConnection(name: "Test NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "owner", musicPath: "/music")
    var supported = true
    var local: [String: String] = [:]
    var cloud: [String: String] = [:]
    var cloudReads: [ServerConnection] = []
    var cloudWrites: [ServerConnection] = []
    var cloudDeletes: [ServerConnection] = []
    var localDeletes: [String] = []
    var logins: [Login] = []
    var loggedOut: [String] = []
    var saveSucceeds = true
    var deleteSucceeds = true
    var loginResult: ((Login) async throws -> DSMSession)?

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "watchFolder")
        defaults.set(3, forKey: "coverCacheVersion")
    }

    var preferenceKey: String { "credentialSync.\(saved.sourceID)" }
    var family: FamilyInfo {
        FamilyInfo(name: "Test family", serverName: saved.name, serverAccount: saved.account,
                   musicPath: saved.musicPath, updatedAt: .now, address: saved.baseURL.absoluteString)
    }

    var catalogue: Catalogue {
        var value = SampleLibrary.catalogue
        value.driveID = saved.sourceID
        value.rootPath = saved.musicPath!
        value.indexedAt = .now
        return value
    }

    func makeModel(restore: Bool = false) -> AppModel {
        var services = ConnectionServices()
        services.observeNetwork = { _ in {} }
        services.supportsCredentialSync = { self.supported }
        services.syncedPassword = {
            self.cloudReads.append($0)
            return self.cloud[$0.sourceID]
        }
        services.saveSyncedPassword = { password, connection in
            self.cloudWrites.append(connection)
            guard self.saveSucceeds else { return false }
            self.cloud[connection.sourceID] = password
            return true
        }
        services.deleteSyncedPassword = { connection in
            self.cloudDeletes.append(connection)
            guard self.deleteSucceeds else { return false }
            self.cloud.removeValue(forKey: connection.sourceID)
            return true
        }
        services.password = { self.local[$0] }
        services.savePassword = { self.local[$1] = $0 }
        services.deletePassword = {
            self.localDeletes.append($0)
            self.local.removeValue(forKey: $0)
        }
        services.login = { url, account, password, otp in
            let attempt = Login(url: url, account: account, password: password, otp: otp)
            self.logins.append(attempt)
            if let result = self.loginResult { return try await result(attempt) }
            return DSMSession(baseURL: url, sid: "fixture-session", apis: [:], account: account)
        }
        services.info = { _ in nil }
        services.logout = { self.loggedOut.append($0.sid) }
        services.loadCatalogue = { self.catalogue }
        services.deleteCatalogue = {}
        services.log = { _ in }
        // A matching, fresh catalogue ensures successful logins never scan a real NAS in these tests.
        library.replace(with: catalogue, drive: nil)
        return AppModel(library: library, defaults: defaults, services: services, restoresSession: restore)
    }

    func rememberConnection() throws {
        defaults.set(try JSONEncoder().encode(saved), forKey: "connection")
    }

    func connectedModel() async throws -> AppModel {
        local[saved.keychainAccount] = "local-password"
        try rememberConnection()
        let model = makeModel(restore: true)
        try await credentialWaitUntil { !model.isRestoring }
        #expect(model.isConnected)
        return model
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor private final class CredentialPendingLogin {
    var continuation: CheckedContinuation<DSMSession, any Error>?

    func start(_ login: CredentialSyncFixture.Login) async throws -> DSMSession {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: DSMSession(baseURL: URL(string: "https://nas.example:5001")!, sid: "late-cloud-session", apis: [:]))
        continuation = nil
    }
}

@MainActor private func credentialWaitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "The controlled credential operation should have reached its expected state")
}

@Suite @MainActor struct CredentialSyncTests {
    @Test func savingAnOrdinarySignInDoesNotPublishWithoutOptIn() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = f.makeModel()
        #expect(model.enterAddress(f.saved.baseURL.absoluteString))
        await model.signIn(account: f.saved.account, password: "entered-password", otpCode: "", remember: true)
        #expect(model.isConnected)
        #expect(f.local[f.saved.keychainAccount] == "entered-password")
        #expect(f.cloudWrites.isEmpty)
        #expect(!model.syncCredentialsAcrossDevices)
    }

    @Test func successfulSignInCanPublishOnlyItsExactSource() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = f.makeModel()
        #expect(model.enterAddress(f.saved.baseURL.absoluteString))
        await model.signIn(account: f.saved.account, password: "entered-password", otpCode: "", remember: true, syncCredentials: true)
        #expect(model.isConnected)
        #expect(model.syncCredentialsAcrossDevices)
        #expect(f.cloud[f.saved.sourceID] == "entered-password")
        #expect(f.cloudWrites.map(\.sourceID) == [f.saved.sourceID])
        #expect(f.defaults.bool(forKey: f.preferenceKey))
    }

    @Test func optInPublishesExistingLocalPasswordAndOptOutPreservesLocalSignIn() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        model.setCredentialSyncEnabled(true)
        #expect(model.syncCredentialsAcrossDevices)
        #expect(f.cloud[f.saved.sourceID] == "local-password")
        #expect(model.credentialSyncError == nil)
        model.setCredentialSyncEnabled(false)
        #expect(!model.syncCredentialsAcrossDevices)
        #expect(f.cloud[f.saved.sourceID] == nil)
        #expect(f.cloudDeletes.map(\.sourceID) == [f.saved.sourceID])
        #expect(f.local[f.saved.keychainAccount] == "local-password")
        #expect(model.isConnected)
    }

    @Test func failedCloudSaveDoesNotPretendSyncWasEnabled() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        f.saveSucceeds = false
        model.setCredentialSyncEnabled(true)
        #expect(!model.syncCredentialsAcrossDevices)
        #expect(model.credentialSyncError != nil)
        #expect(f.local[f.saved.keychainAccount] == "local-password")
        #expect(model.isConnected)
        f.saveSucceeds = true
        model.setCredentialSyncEnabled(true)
        #expect(model.syncCredentialsAcrossDevices)
        #expect(model.credentialSyncError == nil)
    }

    @Test func failedCloudRemovalIsReportedWithoutDeletingLocalPassword() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        model.setCredentialSyncEnabled(true)
        f.deleteSucceeds = false
        model.setCredentialSyncEnabled(false)
        #expect(model.credentialSyncError != nil)
        #expect(f.cloud[f.saved.sourceID] == "local-password")
        #expect(f.local[f.saved.keychainAccount] == "local-password")
        f.deleteSucceeds = true
        model.setCredentialSyncEnabled(false)
        #expect(!model.syncCredentialsAcrossDevices)
        #expect(model.credentialSyncError == nil)
        #expect(f.cloud[f.saved.sourceID] == nil)
    }

    @Test func aFailedPasswordUpdateDoesNotKeepPreferringTheStaleCloudSecret() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        model.setCredentialSyncEnabled(true)
        f.saveSucceeds = false
        #expect(model.enterAddress(f.saved.baseURL.absoluteString))
        await model.signIn(account: f.saved.account, password: "updated-password", otpCode: "", remember: true, syncCredentials: true)
        #expect(model.isConnected)
        #expect(model.credentialSyncError != nil)
        #expect(!model.syncCredentialsAcrossDevices)
        #expect(f.local[f.saved.keychainAccount] == "updated-password")
        #expect(f.cloud[f.saved.sourceID] == "local-password")
        await model.reconnect()
        #expect(f.logins.last?.password == "updated-password")
    }

    @Test func unsupportedPlatformCannotPublishPersonalPassword() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.supported = false
        let model = try await f.connectedModel()
        #expect(!model.supportsCredentialSync)
        model.setCredentialSyncEnabled(true)
        #expect(!model.syncCredentialsAcrossDevices)
        #expect(f.cloudWrites.isEmpty)
        #expect(f.cloudReads.isEmpty)
        #expect(f.local[f.saved.keychainAccount] == "local-password")
    }

    @Test func ownerUsesPersonalSyncedCredentialBeforeSharedFamilyAccount() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "personal-cloud-password"
        var family = f.family
        family.familyAccount = "family-reader"
        family.familyPassword = "family-password"
        let model = f.makeModel()
        await model.useCloudLibrary(family, isOwner: true)
        #expect(model.isConnected)
        #expect(model.connection?.sourceID == f.saved.sourceID)
        #expect(model.connection?.musicPath == "/music")
        #expect(f.logins.count == 1)
        #expect(f.logins.first?.account == "owner")
        #expect(f.logins.first?.password == "personal-cloud-password")
        #expect(f.cloudReads.map(\.sourceID) == [f.saved.sourceID])
        #expect(model.stage == .ready)
        #expect(!model.isScanning)
    }

    @Test func ownerFamilyArrivalCannotRaceAheadOfThePersonalSignInChoice() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "personal-cloud-password"
        var family = f.family
        family.familyAccount = "family-reader"
        family.familyPassword = "shared-family-password"
        let model = f.makeModel()
        model.familyArrived(family, isOwner: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(f.logins.isEmpty)
        #expect(f.cloudReads.isEmpty)
        #expect(model.stage == .welcome)
        await model.useCloudLibrary(family, isOwner: true)
        #expect(f.logins.count == 1)
        #expect(f.logins.first?.account == f.saved.account)
        #expect(model.isConnected)
    }

    @Test func ownerWithoutSyncedSecretGetsSignInWithoutAnyLoginAttempt() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = f.makeModel()
        await model.useCloudLibrary(f.family, isOwner: true)
        #expect(model.stage == .discovering)
        #expect(model.pendingServer?.baseURL == f.saved.baseURL)
        #expect(model.pendingFamilyAccount == f.saved.account)
        #expect(model.pendingReconnectPassword == nil)
        #expect(f.logins.isEmpty)
        #expect(f.cloudWrites.isEmpty)
    }

    @Test func personalCredentialLookupKeepsSchemePortAndAccountBoundaries() async {
        for changed in ["scheme", "port", "account"] {
            let f = CredentialSyncFixture(); defer { f.cleanUp() }
            f.cloud[f.saved.sourceID] = "original-source-password"
            var family = f.family
            switch changed {
            case "scheme": family.address = "http://nas.example:5001"
            case "port": family.address = "https://nas.example:5002"
            default: family.serverAccount = "another-owner"
            }
            let model = f.makeModel()
            await model.useCloudLibrary(family, isOwner: true)
            #expect(f.logins.isEmpty, "A password from another \(changed) must not be reused")
            #expect(f.cloudReads.allSatisfy { $0.sourceID != f.saved.sourceID })
            #expect(model.pendingReconnectPassword == nil)
        }
    }

    @Test func familyMemberNeverReadsOwnersPersonalCredential() async {
        for sharedPassword in [false, true] {
            let f = CredentialSyncFixture(); defer { f.cleanUp() }
            f.cloud[f.saved.sourceID] = "private-owner-password"
            f.loginResult = { _ in throw SynologyError.api(code: 400, api: "SYNO.API.Auth") }
            var family = f.family
            if sharedPassword {
                family.familyAccount = "family-reader"
                family.familyPassword = "shared-family-password"
            }
            let model = f.makeModel()
            await model.useCloudLibrary(family, isOwner: false)
            #expect(f.cloudReads.isEmpty)
            #expect(f.cloudWrites.isEmpty)
            #expect(f.logins.count == (sharedPassword ? 1 : 0))
            #expect(f.logins.allSatisfy { $0.account == "family-reader" && $0.password == "shared-family-password" })
            #expect(model.connection == nil)
        }
    }

    @Test func personalCloudSignInPreservesPasswordOnlyForOTP() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "otp-cloud-password"
        f.loginResult = { _ in throw SynologyError.twoFactorRequired }
        let model = f.makeModel()
        await model.useCloudLibrary(f.family, isOwner: true)
        #expect(model.needsOTP)
        #expect(model.pendingReconnectPassword == "otp-cloud-password")
        #expect(model.pendingServer?.baseURL == f.saved.baseURL)
        #expect(model.pendingFamilyAccount == f.saved.account)
        #expect(model.pendingFamilyPassword == "otp-cloud-password")
        #expect(f.cloudWrites.isEmpty)
        #expect(model.connection == nil)
        model.cancelSignIn()
        #expect(model.pendingReconnectPassword == nil)
    }

    @Test func successfulOTPCompletionKeepsTheSyncedFolderAndClearsTransientPassword() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "otp-cloud-password"
        f.loginResult = { login in
            guard login.otp == "123456" else { throw SynologyError.twoFactorRequired }
            return DSMSession(baseURL: login.url, sid: "otp-session", apis: [:], account: login.account)
        }
        let model = f.makeModel()
        await model.useCloudLibrary(f.family, isOwner: true)
        #expect(model.pendingFamilyPassword == "otp-cloud-password")
        await model.signIn(account: f.saved.account, password: "otp-cloud-password", otpCode: "123456", remember: true, syncCredentials: true)
        #expect(model.isConnected)
        #expect(model.stage == .ready)
        #expect(model.connection?.musicPath == "/music")
        #expect(!model.isScanning)
        #expect(!model.needsOTP)
        #expect(model.pendingReconnectPassword == nil)
        #expect(model.pendingFamilyPassword == nil)
        #expect(model.syncCredentialsAcrossDevices)
    }

    @Test func optingOutDuringOTPRemovesTheReceivedCloudCopyWithoutAnExistingLocalPreference() async {
        for remember in [false, true] {
            for removalSucceeds in [false, true] {
                let f = CredentialSyncFixture(); defer { f.cleanUp() }
                f.cloud[f.saved.sourceID] = "received-password"
                f.local[f.saved.legacyKeychainAccount] = "legacy-password"
                f.deleteSucceeds = removalSucceeds
                f.loginResult = { login in
                    guard login.otp == "123456" else { throw SynologyError.twoFactorRequired }
                    return DSMSession(baseURL: login.url, sid: "otp-session", apis: [:], account: login.account)
                }
                let model = f.makeModel()
                await model.useCloudLibrary(f.family, isOwner: true)
                #expect(f.defaults.object(forKey: f.preferenceKey) == nil)
                await model.signIn(account: f.saved.account, password: "received-password", otpCode: "123456", remember: remember, syncCredentials: false)
                #expect(model.isConnected)
                #expect(f.cloudDeletes.map(\.sourceID) == [f.saved.sourceID])
                #expect(f.cloud[f.saved.sourceID] == (removalSucceeds ? nil : "received-password"))
                #expect((model.credentialSyncError != nil) == !removalSucceeds)
                #expect(model.syncCredentialsAcrossDevices == (remember && !removalSucceeds))
                if !remember {
                    #expect(f.local[f.saved.keychainAccount] == nil)
                    #expect(f.local[f.saved.legacyKeychainAccount] == nil)
                    f.cloudReads.removeAll()
                    let reopened = f.makeModel(restore: true)
                    #expect(!reopened.isConnected)
                    #expect(reopened.pendingServer?.baseURL == f.saved.baseURL)
                    #expect(f.cloudReads.isEmpty, "Remember me off must not restore a cloud copy whose deletion is still pending")
                }
            }
        }
    }

    @Test func rejectedPersonalCloudPasswordFallsBackToManualSignIn() async {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "old-cloud-password"
        f.loginResult = { _ in throw SynologyError.api(code: 400, api: "SYNO.API.Auth") }
        let model = f.makeModel()
        await model.useCloudLibrary(f.family, isOwner: true)
        #expect(!model.isConnected)
        #expect(!model.needsOTP)
        #expect(model.pendingServer?.baseURL == f.saved.baseURL)
        #expect(model.pendingReconnectPassword == nil)
        #expect(model.signInError != nil)
        #expect(f.cloudDeletes.isEmpty, "A rejection must not erase credentials on the user's other devices")
    }

    @Test func lateCloudLoginCannotReplaceAUserSelectedServer() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.cloud[f.saved.sourceID] = "cloud-password"
        let pending = CredentialPendingLogin()
        f.loginResult = pending.start
        let model = f.makeModel()
        let task = Task { await model.useCloudLibrary(f.family, isOwner: true) }
        try await credentialWaitUntil { pending.continuation != nil }
        #expect(model.enterAddress("https://other.example:5001"))
        pending.finish()
        await task.value
        #expect(model.connection == nil)
        #expect(model.pendingServer?.host == "other.example")
        #expect(!model.isConnected)
        #expect(f.loggedOut == ["late-cloud-session"])
        #expect(f.local.isEmpty)
        #expect(f.cloudWrites.isEmpty)
    }

    @Test func restoreAndReconnectPreferCloudOnlyForTheOptedInSource() async throws {
        for optedIn in [false, true] {
            let f = CredentialSyncFixture(); defer { f.cleanUp() }
            f.local[f.saved.keychainAccount] = "local-password"
            f.cloud[f.saved.sourceID] = "rotated-cloud-password"
            f.defaults.set(optedIn, forKey: f.preferenceKey)
            try f.rememberConnection()
            let model = f.makeModel(restore: true)
            try await credentialWaitUntil { !model.isRestoring }
            #expect(model.isConnected)
            await model.reconnect()
            #expect(f.logins.count == 2)
            #expect(f.logins.allSatisfy { $0.password == (optedIn ? "rotated-cloud-password" : "local-password") })
            if !optedIn { #expect(f.cloudReads.isEmpty) }
        }
    }

    @Test func temporaryCloudKeychainAbsenceFallsBackToTheLocalPassword() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.local[f.saved.keychainAccount] = "offline-local-password"
        f.defaults.set(true, forKey: f.preferenceKey)
        try f.rememberConnection()
        let model = f.makeModel(restore: true)
        try await credentialWaitUntil { !model.isRestoring }
        #expect(model.isConnected)
        await model.reconnect()
        #expect(f.logins.count == 2)
        #expect(f.logins.allSatisfy { $0.password == "offline-local-password" })
        #expect(f.cloudWrites.isEmpty, "A missing cloud item must not silently republish an older password")
    }

    @Test func familyPasswordRotationCannotBeOverriddenByAnOlderSyncedCopy() async throws {
        for saveSucceeds in [false, true] {
            let f = CredentialSyncFixture(); defer { f.cleanUp() }
            let model = try await f.connectedModel()
            model.setCredentialSyncEnabled(true)
            f.saveSucceeds = saveSucceeds
            var family = f.family
            family.familyAccount = f.saved.account
            family.familyPassword = "rotated-family-password"
            model.familyArrived(family)
            try await credentialWaitUntil { f.logins.count >= 2 && !model.isReconnecting }
            #expect(f.local[f.saved.keychainAccount] == "rotated-family-password")
            #expect(f.logins.last?.password == "rotated-family-password")
            #expect(model.syncCredentialsAcrossDevices == saveSucceeds)
            #expect((model.credentialSyncError != nil) == !saveSucceeds)
            #expect(model.isConnected)
        }
    }

    @Test func successfulCloudRestoreRefreshesTheLocalOfflineFallback() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        f.local[f.saved.keychainAccount] = "stale-local-password"
        f.cloud[f.saved.sourceID] = "current-cloud-password"
        f.defaults.set(true, forKey: f.preferenceKey)
        try f.rememberConnection()
        let model = f.makeModel(restore: true)
        try await credentialWaitUntil { !model.isRestoring }
        #expect(model.isConnected)
        #expect(f.local[f.saved.keychainAccount] == "current-cloud-password")
        f.cloud.removeValue(forKey: f.saved.sourceID)
        await model.reconnect()
        #expect(f.logins.last?.password == "current-cloud-password")
        #expect(f.cloudWrites.isEmpty)
    }

    @Test func explicitPublishingUsesTheVerifiedLocalPasswordRatherThanAnOldCloudCopy() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        model.setCredentialSyncEnabled(true)
        f.cloud[f.saved.sourceID] = "stale-cloud-password"
        model.setCredentialSyncEnabled(true)
        #expect(f.cloud[f.saved.sourceID] == "local-password")
        #expect(model.credentialSyncError == nil)
    }

    @Test func signOutRemovesLocalAccessWithoutDeletingCloudCredential() async throws {
        let f = CredentialSyncFixture(); defer { f.cleanUp() }
        let model = try await f.connectedModel()
        model.setCredentialSyncEnabled(true)
        await model.signOut()
        #expect(model.connection == nil)
        #expect(!model.isConnected)
        #expect(f.local[f.saved.keychainAccount] == nil)
        #expect(f.cloud[f.saved.sourceID] == "local-password")
        #expect(f.cloudDeletes.isEmpty)
    }
}
