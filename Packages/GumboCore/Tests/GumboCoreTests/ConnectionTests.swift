import Foundation
import Testing
@testable import GumboCore

@MainActor private final class ConnectionFixture {
    let suite = "GumboConnectionTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let library = LibraryStore()
    var services = ConnectionServices()
    var loggedOut: [String] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: "coverCacheVersion")
        services.password = { _ in "test password" }
        services.savePassword = { _, _ in }
        services.deletePassword = { _ in }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
        services.info = { _ in nil }
        services.logout = { [weak self] in self?.loggedOut.append($0.sid) }
        services.observeNetwork = { _ in {} }
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    func model(restore: Bool = false) -> AppModel {
        AppModel(library: library, defaults: defaults, services: services, restoresSession: restore)
    }
    func save(_ connection: ServerConnection) throws {
        defaults.set(try JSONEncoder().encode(connection), forKey: "connection")
    }
}

@MainActor private final class PendingLogin {
    var continuation: CheckedContinuation<DSMSession, Error>?
    func login(_ url: URL, _ account: String, _ password: String, _ otp: String?) async throws -> DSMSession {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ sid: String = "test-session") {
        continuation?.resume(returning: DSMSession(baseURL: URL(string: "https://nas.example:5001")!, sid: sid, apis: [:]))
        continuation = nil
    }
    func fail(_ error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "The controlled asynchronous operation should have started")
}

@Test @MainActor func cancelledSignInDoesNotInstallItsSession() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    let task = Task { await model.signIn(account: "listener", password: "test", otpCode: "", remember: false) }
    try await waitUntil { login.continuation != nil }
    model.cancelSignIn()
    login.finish()
    await task.value
    #expect(model.connection == nil)
    #expect(!model.isConnected)
    #expect(model.pendingServer == nil)
    #expect(fixture.defaults.data(forKey: "connection") == nil)
    #expect(fixture.loggedOut == ["test-session"])
}

@Test @MainActor func supersededSignInLeavesTheNewSelectionIntact() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    let task = Task { await model.signIn(account: "listener", password: "test", otpCode: "", remember: false) }
    try await waitUntil { login.continuation != nil }
    #expect(model.enterAddress("https://other.example:5001"))
    login.finish()
    await task.value
    #expect(model.pendingServer?.host == "other.example")
    #expect(model.connection == nil)
    #expect(!model.isSigningIn)
}

@Test @MainActor func ordinarySignInOpensFolderSelection() async {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    fixture.services.login = { url, _, _, _ in DSMSession(baseURL: url, sid: "ordinary", apis: [:]) }
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    await model.signIn(account: "listener", password: "test", otpCode: "", remember: false)
    #expect(model.isConnected)
    #expect(model.connection?.account == "listener")
    #expect(model.stage == .chooseFolder)
    #expect(model.pendingServer == nil)
    #expect(!model.isSigningIn)
    #expect(fixture.loggedOut.isEmpty)
}

@Test @MainActor func restoreRequestsOTPWithoutDiscardingMatchingOfflineLibrary() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    var suppliedCodes: [String?] = []
    fixture.services.login = { url, _, _, otp in
        suppliedCodes.append(otp)
        guard otp == "123456" else { throw SynologyError.twoFactorRequired }
        return DSMSession(baseURL: url, sid: "reauthenticated", apis: [:])
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.needsOTP)
    #expect(model.pendingServer?.host == saved.host)
    #expect(fixture.library.catalogue.trackCount == catalogue.trackCount)
    await model.signIn(account: saved.account, password: "test", otpCode: "123456", remember: false)
    #expect(model.stage == .ready)
    #expect(model.isConnected)
    #expect(!model.needsOTP)
    #expect(fixture.library.catalogue.trackCount == catalogue.trackCount)
    #expect(suppliedCodes.count == 2)
}

@Test @MainActor func cancelledRestoreDoesNotReplaceSampleLibrary() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    try fixture.save(ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music"))
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model(restore: true)
    try await waitUntil { login.continuation != nil }
    model.useSampleLibrary()
    model.openLibrary()
    login.finish()
    try await waitUntil { !fixture.loggedOut.isEmpty }
    #expect(model.isDemo)
    #expect(model.connection == nil)
    #expect(model.stage == .ready)
    #expect(!model.isConnected)
}

@Test func catalogueRequiresBothServerAndFolder() {
    let connection = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    var catalogue = Catalogue.empty
    catalogue.driveID = connection.sourceID
    catalogue.rootPath = "/music"
    #expect(catalogue.belongs(to: connection))
    catalogue.rootPath = "/other"
    #expect(!catalogue.belongs(to: connection))
    catalogue.rootPath = "/music"
    catalogue.driveID = "other.example"
    #expect(!catalogue.belongs(to: connection))
}

@Test @MainActor func restoreWithoutCacheShowsReauthenticationOnEveryPlatform() async throws {
    for needsOTP in [false, true] {
        let fixture = ConnectionFixture()
        defer { fixture.cleanUp() }
        try fixture.save(ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music"))
        fixture.services.password = { _ in needsOTP ? "test" : nil }
        fixture.services.login = { _, _, _, _ in throw SynologyError.twoFactorRequired }
        let model = fixture.model(restore: true)
        try await waitUntil { !model.isRestoring }
        #expect(model.stage == .discovering)
        #expect(model.pendingServer?.host == "nas.example")
        #expect(model.needsOTP == needsOTP)
        #expect(fixture.library.isEmpty)
    }
}

@Test @MainActor func changingTheFolderInvalidatesAnOutstandingReconnect() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let pending = PendingLogin()
    var calls = 0
    fixture.services.login = { url, account, password, otp in
        calls += 1
        if calls == 1 { return DSMSession(baseURL: url, sid: "restored", apis: [:]) }
        return try await pending.login(url, account, password, otp)
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let task = Task { await model.reconnect() }
    try await waitUntil { pending.continuation != nil }
    fixture.library.drive = FakeDrive(tree: [:])
    model.chooseMusicFolder(path: "/new-music", showsProgress: false)
    model.indexer.cancel()
    pending.finish("late-reconnect")
    await task.value
    #expect(model.musicPath == "/new-music")
    #expect(fixture.library.drive?.id == "fake")
    #expect(fixture.loggedOut == ["late-reconnect"])
    let data = try #require(fixture.defaults.data(forKey: "connection"))
    #expect(try JSONDecoder().decode(ServerConnection.self, from: data).musicPath == "/new-music")
}

@Test @MainActor func twoFactorRequiredDuringRestoreStoresPasswordForOTPOnlyReauth() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let storedPassword = "remembered-password"
    fixture.services.password = { _ in storedPassword }
    fixture.services.login = { _, _, _, _ in throw SynologyError.twoFactorRequired }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.needsOTP)
    #expect(model.pendingReconnectPassword == storedPassword, "The stored password should be available for OTP-only reauth")
    #expect(model.signInError == "Enter the code from your authenticator app to reconnect.")
}

@Test @MainActor func twoFactorRequiredDuringReconnectStoresPasswordForOTPOnlyReauth() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let storedPassword = "remembered-password"
    fixture.services.password = { _ in storedPassword }
    var loginCalls = 0
    fixture.services.login = { url, _, _, otp in
        loginCalls += 1
        if loginCalls == 1 { return DSMSession(baseURL: url, sid: "initial", apis: [:]) }
        throw SynologyError.twoFactorRequired
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.isConnected)
    await model.reconnect()
    #expect(model.needsOTP)
    #expect(model.pendingReconnectPassword == storedPassword, "The stored password should be available for OTP-only reauth")
}

@Test @MainActor func successfulSignInClearsPendingReconnectPassword() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let storedPassword = "remembered-password"
    fixture.services.password = { _ in storedPassword }
    var loginCalls = 0
    fixture.services.login = { url, _, _, otp in
        loginCalls += 1
        if otp == nil { throw SynologyError.twoFactorRequired }
        return DSMSession(baseURL: url, sid: "reauthenticated", apis: [:])
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.pendingReconnectPassword == storedPassword)
    await model.signIn(account: saved.account, password: storedPassword, otpCode: "123456", remember: false)
    #expect(model.isConnected)
    #expect(model.pendingReconnectPassword == nil, "Pending password should be cleared after successful sign-in")
}

@Test @MainActor func cancelSignInClearsPendingReconnectPassword() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let storedPassword = "remembered-password"
    fixture.services.password = { _ in storedPassword }
    fixture.services.login = { _, _, _, _ in throw SynologyError.twoFactorRequired }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.pendingReconnectPassword == storedPassword)
    model.cancelSignIn()
    #expect(model.pendingReconnectPassword == nil, "Pending password should be cleared when sign-in is cancelled")
}

@Test @MainActor func rejectedSavedPasswordRequestsLoginWithCachedLibraryOnRestoreAndReconnect() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try f.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    f.services.loadCatalogue = { catalogue }
    f.services.login = { _, _, _, _ in throw SynologyError.api(code: 400, api: "SYNO.API.Auth") }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.stage == .ready && model.pendingServer?.host == saved.host && !model.needsOTP)
    #expect(f.library.catalogue.trackCount == catalogue.trackCount)
    model.cancelSignIn()
    await model.reconnect()
    #expect(model.pendingServer?.host == saved.host)
    #expect(f.library.catalogue.trackCount == catalogue.trackCount)
}

// MARK: - Offline launches and ended sessions

extension ConnectionFixture {
    /// A saved server whose cached library opens before the server answers. Automatic library
    /// refreshes are off, so no scan runs alongside the connection under test.
    func saveLibrary() throws -> ServerConnection {
        let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
        try save(saved)
        var catalogue = SampleLibrary.catalogue
        catalogue.driveID = saved.sourceID
        catalogue.rootPath = "/music"
        services.loadCatalogue = { catalogue }
        defaults.set(false, forKey: "watchFolder")
        return saved
    }
}

private nonisolated func fileStationSession(_ url: URL, _ sid: String) -> DSMSession {
    let fileStation = SynologyAPIDescriptor(path: "entry.cgi", minVersion: 1, maxVersion: 2)
    return DSMSession(baseURL: url, sid: sid, apis: ["SYNO.FileStation.List": fileStation, "SYNO.FileStation.Download": fileStation],
                      account: "listener")
}

/// A drive whose first session, "restored", has since been ended by the server.
private nonisolated func expiringDrive(_ session: DSMSession, _ name: String, _ renewal: @escaping SynologyDrive.SessionRenewal) -> SynologyDrive {
    SynologyDrive(session: session, displayName: name, renewal: renewal) { url in
        let sid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "_sid" }?.value
        guard sid != "restored" else { throw SynologyError.api(code: 119, api: "SYNO.FileStation.List") }
        return SynologyFileList(files: [], offset: 0, total: 0)
    }
}

@Test @MainActor func offlineLaunchReconnectsWhenTheAppBecomesActive() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    var reachable = false
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        guard reachable else { throw SynologyError.unreachable("The request timed out.") }
        return DSMSession(baseURL: url, sid: "home", apis: [:])
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.stage == .ready && !model.isConnected)
    #expect(model.pendingServer == nil)
    reachable = true
    model.scenePhaseChanged(.active)
    try await waitUntil { model.isConnected }
    #expect(logins == 2)
    #expect(model.signInError == nil)
    #expect(model.pendingServer == nil)
    #expect(model.connection == saved)
    #expect(f.library.catalogue.trackCount == SampleLibrary.catalogue.trackCount)
}

@Test @MainActor func automaticReconnectionStaysQuietAndIsSpacedOut() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { _, _, _, _ in
        logins += 1
        throw SynologyError.unreachable("The request timed out.")
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    model.scenePhaseChanged(.active)
    try await waitUntil { logins == 2 && !model.isReconnecting }
    // Coming straight back waits for the interval instead of asking the server again.
    model.scenePhaseChanged(.inactive)
    model.scenePhaseChanged(.active)
    await model.waitForDrive(upTo: .milliseconds(30))
    #expect(logins == 2)
    // A server that can't be reached never brings up the sign-in sheet.
    #expect(model.pendingServer == nil && !model.needsOTP)
    #expect(model.stage == .ready && !model.isConnected)
    #expect(model.signInError != nil)
    model.automaticReconnectInterval = .zero
    model.scenePhaseChanged(.active)
    try await waitUntil { logins == 3 && !model.isReconnecting }
    #expect(model.pendingServer == nil)
}

@Test @MainActor func automaticReconnectionWaitsForThePersonAfterARefusedSignIn() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    var logins = 0
    f.services.login = { _, _, _, _ in
        logins += 1
        throw SynologyError.api(code: 400, api: "SYNO.API.Auth")
    }
    let model = f.model(restore: true)
    model.automaticReconnectInterval = .zero
    try await waitUntil { !model.isRestoring }
    #expect(model.pendingServer?.host == saved.host)
    model.cancelSignIn()
    for _ in 0..<3 { model.scenePhaseChanged(.active) }
    await model.waitForDrive(upTo: .milliseconds(30))
    #expect(logins == 1)
    #expect(model.pendingServer == nil)
    // Reconnect stays available whenever someone asks for it.
    await model.reconnect()
    #expect(logins == 2)
    #expect(model.pendingServer?.host == saved.host)
}

@Test @MainActor func anAutomaticAttemptThatIsRefusedAsksOnceAndStops() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    var logins = 0
    f.services.login = { _, _, _, _ in
        logins += 1
        // Launched away from home; back home, DSM turns the saved password down.
        guard logins > 1 else { throw SynologyError.unreachable("The request timed out.") }
        throw SynologyError.api(code: 400, api: "SYNO.API.Auth")
    }
    let model = f.model(restore: true)
    model.automaticReconnectInterval = .zero
    try await waitUntil { !model.isRestoring }
    #expect(model.pendingServer == nil)
    model.scenePhaseChanged(.active)
    try await waitUntil { model.pendingServer != nil }
    #expect(logins == 2)
    #expect(model.pendingServer?.host == saved.host)
    #expect(model.stage == .ready && !model.isConnected)
    model.cancelSignIn()
    for _ in 0..<3 { model.scenePhaseChanged(.active) }
    await model.waitForDrive(upTo: .milliseconds(30))
    #expect(logins == 2)
    #expect(model.pendingServer == nil)
}

/// The app becomes active, as it does right after launch, while the launch sign-in still waits
/// for the server.
@Test(arguments: [true, false])
@MainActor func aTriggerDuringTheLaunchSignInIsAnsweredOnlyIfThatFails(_ launchConnects: Bool) async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        if logins == 1 { return try await pending.login(url, account, password, otp) }
        return DSMSession(baseURL: url, sid: "home", apis: [:])
    }
    let model = f.model(restore: true)
    try await waitUntil { pending.continuation != nil }
    model.scenePhaseChanged(.active)
    await model.waitForDrive(upTo: .milliseconds(30))
    // No second sign-in alongside the first, and no follow-up waiting out the interval.
    #expect(logins == 1)
    #expect(model.pendingAutomaticReconnect == nil)
    #expect(model.reconnectRequestedDuringAttempt)
    if launchConnects {
        pending.finish("launch")
    } else {
        // For example, it set out on the network the app launched on.
        pending.fail(SynologyError.unreachable("The network connection was lost."))
    }
    try await waitUntil { model.isConnected && !model.isReconnecting }
    #expect(logins == (launchConnects ? 1 : 2))
    #expect(!model.reconnectRequestedDuringAttempt)
    #expect(model.pendingServer == nil)
}

@Test @MainActor func aNetworkChangeDuringAnAutomaticAttemptIsAnsweredWhenItFails() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var networkChanged: (@Sendable () -> Void)?
    f.services.observeNetwork = { onChange in
        networkChanged = onChange
        return {}
    }
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        switch logins {
        case 1: throw SynologyError.unreachable("The request timed out.")
        case 2: return try await pending.login(url, account, password, otp)
        default: return DSMSession(baseURL: url, sid: "home", apis: [:])
        }
    }
    let model = f.model(restore: true)
    model.automaticReconnectInterval = .zero
    try await waitUntil { !model.isRestoring }
    model.scenePhaseChanged(.active)
    try await waitUntil { pending.continuation != nil }
    // Home Wi-Fi comes up while that attempt is still on its way over the network it set out on.
    networkChanged?()
    try await waitUntil { model.reconnectRequestedDuringAttempt }
    #expect(logins == 2)
    pending.fail(SynologyError.unreachable("The network connection was lost."))
    try await waitUntil { model.isConnected && !model.isReconnecting }
    #expect(logins == 3)
    #expect(model.pendingServer == nil)
}

@Test @MainActor func networkChangeReconnectsAnOfflineLibraryUntilSignOut() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var networkChanged: (@Sendable () -> Void)?
    var observers = 0
    var stops = 0
    f.services.observeNetwork = { onChange in
        observers += 1
        networkChanged = onChange
        return { stops += 1 }
    }
    var reachable = false
    f.services.login = { url, _, _, _ in
        guard reachable else { throw SynologyError.unreachable("offline") }
        return DSMSession(baseURL: url, sid: "home", apis: [:])
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(observers == 1)
    #expect(!model.isConnected)
    reachable = true
    networkChanged?()
    try await waitUntil { model.isConnected }
    #expect(observers == 1 && stops == 0)
    await model.signOut()
    #expect(stops == 1)
}

/// The Watch keeps its own copy of the sign-in. Signing out ends access handed on with the connection,
/// even when this launch never reached the NAS (#219).
@Test @MainActor func signOutEndsAccessHandedOnWithTheConnectionEvenOffline() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    f.services.login = { _, _, _, _ in throw SynologyError.unreachable("offline") }
    let model = f.model(restore: true)
    var signedOut = 0
    model.onSignedOut = { signedOut += 1 }
    try await waitUntil { !model.isRestoring }
    #expect(!model.isConnected)
    #expect(signedOut == 0)
    await model.signOut()
    #expect(signedOut == 1)
    #expect(model.connection == nil)
}

@Test func onlyAMoveToAnotherUsableNetworkIsReported() {
    var moves = NetworkMoveFilter<String>()
    // The first report is the network the app already had; then the same one again, a move to
    // Wi-Fi, losing the network, and finding Wi-Fi again.
    let reports = [("cellular", true), ("cellular", true), ("wifi", true), ("none", false), ("wifi", true)]
    let reported = reports.map { moves.isMove(to: $0.0, usable: $0.1) }
    #expect(reported == [false, false, true, false, true])
}

@Test @MainActor func endedSessionIsRenewedWithTheSavedPasswordAndSignOutEndsTheNewOne() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins: [String?] = []
    f.services.login = { url, _, password, otp in
        logins.append(otp)
        #expect(password == "test password")
        return fileStationSession(url, logins.count == 1 ? "restored" : "renewed")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    try await drive.checkSession(folder: "/music")
    #expect(logins == [nil, nil])
    #expect(drive.session.sid == "renewed")
    #expect((f.library.drive as? SynologyDrive) === drive)
    #expect(model.isConnected && model.pendingServer == nil)
    await model.signOut()
    #expect(f.loggedOut == ["renewed"])
}

@Test @MainActor func foregroundChecksAnIdleSessionAndRenewsItBeforePlayback() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        return fileStationSession(url, logins == 1 ? "restored" : "renewed")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    // A session that answered moments ago isn't checked.
    model.scenePhaseChanged(.active)
    try await Task.sleep(for: .milliseconds(50))
    #expect(logins == 1)
    #expect(drive.session.sid == "restored")
    model.sessionCheckIdleTime = .zero
    model.scenePhaseChanged(.active)
    try await waitUntil { drive.session.sid == "renewed" }
    #expect(logins == 2)
    #expect(drive.streamURL(for: "/music/a.flac").flatMap(drive.sessionID(of:)) == "renewed")
}

@Test @MainActor func renewalNeedingAOneTimeCodeAsksOnceAndLeavesTheLibraryOffline() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        guard logins == 1 else { throw SynologyError.twoFactorRequired }
        return fileStationSession(url, "restored")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    model.automaticReconnectInterval = .zero
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    #expect(logins == 2)
    #expect(model.needsOTP)
    #expect(model.pendingServer?.host == saved.host)
    #expect(model.pendingReconnectPassword == "test password")
    #expect(model.stage == .ready && !model.isConnected)
    #expect(f.library.catalogue.trackCount == SampleLibrary.catalogue.trackCount)
    // Neither the old drive nor the app coming back signs in again by itself.
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    model.cancelSignIn()
    model.scenePhaseChanged(.active)
    await model.waitForDrive(upTo: .milliseconds(30))
    #expect(logins == 2)
    await model.signOut()
    #expect(f.loggedOut.isEmpty)
}

@Test @MainActor func aDriveLeftBehindBySignOutNeverSignsInAgain() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        return fileStationSession(url, "restored")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    await model.signOut()
    // Declined each time it asks, without a sign-in.
    for _ in 0..<2 {
        await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    }
    #expect(logins == 1)
    #expect(model.pendingServer == nil)
}

@Test @MainActor func aSessionRenewedWhileSigningOutIsEndedAndNeverInstalled() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        if logins == 1 { return fileStationSession(url, "restored") }
        return try await pending.login(url, account, password, otp)
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    let check = Task { try? await drive.checkSession(folder: "/music") }
    try await waitUntil { pending.continuation != nil }
    await model.signOut()
    pending.finish("late-renewal")
    await check.value
    #expect(f.loggedOut == ["restored", "late-renewal"])
    #expect(drive.session.sid == "restored")
    #expect(model.connection == nil && !model.isConnected)
    #expect(logins == 2)
}

/// Renewal fails for want of the person: DSM refuses the saved password (400) or blocks the
/// address (407), or no password was saved (nil).
@Test(arguments: [400, 407, nil] as [Int?])
@MainActor func renewalOnlyThePersonCanPutRightAsksOnceAndKeepsTheLibrary(_ refusal: Int?) async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    var passwordSaved = true
    f.services.password = { _ in passwordSaved ? "test password" : nil }
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        if logins > 1, let refusal { throw SynologyError.api(code: refusal, api: "SYNO.API.Auth") }
        return fileStationSession(url, logins == 1 ? "restored" : "renewed")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    model.automaticReconnectInterval = .zero
    try await waitUntil { !model.isRestoring }
    // Without Remember me the password served only the sign-in that opened the drive.
    if refusal == nil { passwordSaved = false }
    let drive = try #require(f.library.drive as? SynologyDrive)
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    #expect(logins == (refusal == nil ? 1 : 2))
    #expect(!model.needsOTP)
    #expect(model.pendingServer?.host == saved.host)
    #expect(model.stage == .ready && !model.isConnected)
    if let refusal {
        #expect(model.signInError == SynologyError.api(code: refusal, api: "SYNO.API.Auth").localizedDescription)
    } else {
        #expect(model.signInError != nil)
    }
    #expect(f.library.catalogue.trackCount == SampleLibrary.catalogue.trackCount)
    // Neither the old drive nor the app coming back signs in again by itself.
    let asked = logins
    model.cancelSignIn()
    model.scenePhaseChanged(.active)
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    try await Task.sleep(for: .milliseconds(50))
    #expect(logins == asked)
}

/// A server that doesn't answer the renewal, for example while it restarts, needs no one to sign
/// in by hand: the library keeps its drive, and a later request may renew the session.
@Test @MainActor func renewalThatCannotReachTheServerStaysQuietAndKeepsTheLibrary() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        guard logins == 1 else { throw SynologyError.unreachable("The request timed out.") }
        return fileStationSession(url, "restored")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    #expect(logins == 2)
    #expect(model.pendingServer == nil && model.signInError == nil)
    #expect((f.library.drive as? SynologyDrive) === drive && model.isConnected)
    #expect(drive.session.sid == "restored")
}

@Test @MainActor func anEndedSessionWaitsForAReconnectionInProgress() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        if logins == 1 { return fileStationSession(url, "restored") }
        return try await pending.login(url, account, password, otp)
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    let reconnect = Task { await model.reconnect() }
    try await waitUntil { pending.continuation != nil }
    // The reconnection brings its own session; the old drive doesn't sign in alongside it.
    await #expect(throws: SynologyError.self) { try await drive.checkSession(folder: "/music") }
    #expect(logins == 2)
    pending.finish("reconnected")
    await reconnect.value
    #expect((f.library.drive as? SynologyDrive)?.session.sid == "reconnected")
    #expect(logins == 2)
}

@Test @MainActor func automaticReconnectionIsNoNewConnectionIntent() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var reachable = false
    f.services.login = { url, _, _, _ in
        guard reachable else { throw SynologyError.unreachable("The request timed out.") }
        return DSMSession(baseURL: url, sid: "home", apis: [:])
    }
    let model = f.model(restore: true)
    var connectionChanges = 0
    model.onConnectionWillChange = { connectionChanges += 1 }
    try await waitUntil { !model.isRestoring }
    let token = model.playbackConnectionToken
    // A widget link brings the offline app back on an album.
    let album = try #require(f.library.albums.first)
    let navigation = try #require(model.beginAlbumNavigation(album))
    reachable = true
    model.scenePhaseChanged(.active)
    try await waitUntil { model.isConnected }
    model.finishAlbumNavigation(navigation)
    #expect(model.albumToOpen?.id == album.id)
    #expect(model.playbackConnectionToken == token)
    #expect(connectionChanges == 0)
    // Reconnect in Settings still starts over.
    await model.reconnect()
    #expect(model.playbackConnectionToken != token)
    #expect(connectionChanges == 1)
}

@Test @MainActor func anAutomaticAttemptStillSigningInGivesWayToSignOut() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        guard logins > 1 else { throw SynologyError.unreachable("The request timed out.") }
        return try await pending.login(url, account, password, otp)
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    model.scenePhaseChanged(.active)
    try await waitUntil { pending.continuation != nil }
    await model.signOut()
    pending.finish("late-automatic")
    try await waitUntil { f.loggedOut == ["late-automatic"] }
    #expect(model.connection == nil && f.library.drive == nil && !model.isReconnecting)
    #expect(model.stage == .welcome)
}

@Test @MainActor func anAutomaticAttemptStillSigningInGivesWayToReconnect() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    let pending = PendingLogin()
    var logins = 0
    f.services.login = { url, account, password, otp in
        logins += 1
        switch logins {
        case 1: throw SynologyError.unreachable("The request timed out.")
        case 2: return try await pending.login(url, account, password, otp)
        default: return DSMSession(baseURL: url, sid: "asked", apis: [:])
        }
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    model.scenePhaseChanged(.active)
    try await waitUntil { pending.continuation != nil }
    // Reconnect in Settings while the automatic attempt still waits for the server.
    await model.reconnect()
    #expect(model.isConnected && !model.isReconnecting)
    let drive = try #require(f.library.drive as? SynologyDrive)
    #expect(drive.session.sid == "asked")
    pending.finish("late-automatic")
    try await waitUntil { f.loggedOut == ["late-automatic"] }
    #expect((f.library.drive as? SynologyDrive) === drive)
    #expect(logins == 3)
}

@Test @MainActor func aVoiceRequestWaitingForTheServerReconnectsAndPlays() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var reachable = false
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        guard reachable else { throw SynologyError.unreachable("The request timed out.") }
        return DSMSession(baseURL: url, sid: "home", apis: [:])
    }
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let library = f.library
    let profileSession = UUID()
    var command = UUID()
    var played: [String] = []
    let voice = VoicePlaybackController(context: {
        guard model.stage == .ready, model.pendingServer == nil else { return nil }
        return VoicePlaybackContext(sourceID: library.catalogue.driveID, rootPath: library.catalogue.rootPath,
                                    profileID: "listener", sessionID: profileSession,
                                    connectionToken: model.playbackConnectionToken)
    }, content: { (library.albums, []) }, isDownloaded: { _ in false }, isConnected: { model.isConnected },
       waitForConnection: { await model.waitForDrive(upTo: .seconds(2)) },
       beginCommand: { command = UUID(); return command }, currentCommand: { command },
       play: { tracks, _, _, _ in played = tracks.map(\.id); return true })
    let album = try #require(library.albums.first)
    let matches = try await voice.resolve(VoiceMediaQuery(kind: .album, name: album.title))
    let selection = try #require(matches.first)
    reachable = true
    // Waiting for the server reconnects the offline library, and the request carries on.
    try await voice.play(selection)
    #expect(model.isConnected)
    #expect(logins == 2)
    #expect(!played.isEmpty)
}

@Test @MainActor func aTriggerThatComesTooSoonIsFollowedUpOnce() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { _, _, _, _ in
        logins += 1
        throw SynologyError.unreachable("The request timed out.")
    }
    let model = f.model(restore: true)
    // Long enough that the triggers below come within it even while other suites hold the main actor.
    model.automaticReconnectInterval = .seconds(1)
    try await waitUntil { !model.isRestoring }
    model.scenePhaseChanged(.active)
    try await waitUntil { logins == 2 && !model.isReconnecting }
    for _ in 0..<3 { model.scenePhaseChanged(.active) }
    #expect(logins == 2)
    // With nothing else happening, the follow-up comes when the interval is up, and only once.
    try await Task.sleep(for: .seconds(1))
    try await waitUntil { logins == 3 && !model.isReconnecting }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(logins == 3)
    #expect(model.pendingAutomaticReconnect == nil)
    // Signing out cancels a follow-up that is still waiting.
    model.automaticReconnectInterval = .seconds(20)
    model.scenePhaseChanged(.active)
    let followUp = try #require(model.pendingAutomaticReconnect)
    await model.signOut()
    #expect(followUp.isCancelled)
    #expect(logins == 3)
}

@Test(arguments: [true, false])
@MainActor func reconnectingAnOfflineLibraryRefreshesItWhenStale(_ stale: Bool) async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    let saved = try f.saveLibrary()
    f.defaults.set(true, forKey: "watchFolder")
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.sourceID
    catalogue.rootPath = "/music"
    catalogue.indexedAt = stale ? .distantPast : .now
    f.services.loadCatalogue = { catalogue }
    var reachable = false
    f.services.login = { url, _, _, _ in
        guard reachable else { throw SynologyError.unreachable("The request timed out.") }
        return fileStationSession(url, "home")
    }
    // The scan's listing never answers, so a refresh that started is still running.
    f.services.synologyDrive = { session, name, renewal in
        SynologyDrive(session: session, displayName: name, renewal: renewal) { _ in
            try await Task.sleep(for: .seconds(30))
            return SynologyFileList(files: [], offset: 0, total: 0)
        }
    }
    let model = f.model(restore: true)
    defer { model.indexer.cancel() }
    try await waitUntil { !model.isRestoring }
    #expect(!model.isConnected && !model.isScanning)
    reachable = true
    model.scenePhaseChanged(.active)
    try await waitUntil { model.isConnected }
    #expect(model.isScanning == stale)
}

@Test @MainActor func failedStreamIsLoadedAgainOnlyWithAFreshSession() async throws {
    let f = ConnectionFixture(); defer { f.cleanUp() }
    _ = try f.saveLibrary()
    var logins = 0
    f.services.login = { url, _, _, _ in
        logins += 1
        return fileStationSession(url, logins == 1 ? "restored" : "renewed")
    }
    f.services.synologyDrive = expiringDrive
    let model = f.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let drive = try #require(f.library.drive as? SynologyDrive)
    let stale = try #require(drive.streamURL(for: "/music/a.flac"))
    #expect(await model.recoverStream(from: stale))
    #expect(logins == 2)
    // Already renewed: the player may try again without another sign-in.
    #expect(await model.recoverStream(from: stale))
    #expect(logins == 2)
    // A song that failed on a working session, or a downloaded file, is not retried.
    let fresh = try #require(drive.streamURL(for: "/music/a.flac"))
    #expect(await model.recoverStream(from: fresh) == false)
    #expect(await model.recoverStream(from: URL(filePath: "/downloads/a.flac")) == false)
    #expect(logins == 2)
}
