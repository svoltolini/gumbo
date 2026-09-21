import Foundation
import Security
import Synchronization
import Testing
@testable import GumboCore

private nonisolated final class CredentialKeychainFixture: Sendable {
    // Immutable snapshots of Security query dictionaries containing only value types.
    nonisolated struct Call: @unchecked Sendable {
        let name: String
        let query: [String: Any]
        let attributes: [String: Any]
    }
    nonisolated struct State: Sendable {
        var calls: [Call] = []
        var updates: [OSStatus] = [errSecSuccess]
        var add: OSStatus = errSecSuccess
        var copy: (OSStatus, Data?) = (errSecSuccess, Data("fixture password".utf8))
        var delete: OSStatus = errSecSuccess
    }
    let state = Mutex(State())

    var operations: SyncedCredentialKeychainOperations {
        SyncedCredentialKeychainOperations(
            update: { [self] query, attributes in state.withLock {
                $0.calls.append(Call(name: "update", query: query, attributes: attributes))
                return $0.updates.isEmpty ? errSecInternalError : $0.updates.removeFirst()
            } },
            add: { [self] query in state.withLock {
                $0.calls.append(Call(name: "add", query: query, attributes: [:]))
                return $0.add
            } },
            copy: { [self] query in state.withLock {
                $0.calls.append(Call(name: "copy", query: query, attributes: [:]))
                return $0.copy
            } },
            delete: { [self] query in state.withLock {
                $0.calls.append(Call(name: "delete", query: query, attributes: [:]))
                return $0.delete
            } }
        )
    }

    func store(group: String? = "TESTTEAM.com.samuelvoltolini.gumbo", supported: Bool = true) -> SyncedServerCredentialKeychain {
        SyncedServerCredentialKeychain(accessGroup: group, isSupported: supported, operations: operations)
    }
}

private nonisolated func credentialConnection(_ address: String = "https://nas.example:5001", account: String = "listener") -> ServerConnection {
    ServerConnection(name: "NAS", baseURL: URL(string: address)!, account: account, musicPath: "/music")
}

@Test nonisolated func syncedPasswordUsesOnlyPersonalExactAccessGroupAndSyncKeychain() {
    let fixture = CredentialKeychainFixture()
    let store = fixture.store()
    #expect(store.save(password: "fixture password", for: credentialConnection()))
    #expect(store.password(for: credentialConnection()) == "fixture password")
    #expect(store.delete(for: credentialConnection()))
    fixture.state.withLock { state in
        #expect(state.calls.map(\.name) == ["update", "copy", "delete"])
        for call in state.calls {
            #expect(call.query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(call.query[kSecAttrService as String] as? String == "com.samuelvoltolini.gumbo.personal-server-sync.v1")
            #expect(call.query[kSecAttrAccessGroup as String] as? String == "TESTTEAM.com.samuelvoltolini.gumbo")
            #expect(call.query[kSecAttrSynchronizable as String] as? Bool == true)
            #expect(call.query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(call.query[kSecValueData as String] == nil)
            #expect(call.query[kSecReturnRef as String] == nil)
            #expect(call.query[kSecReturnPersistentRef as String] == nil)
        }
        #expect(state.calls[0].attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(state.calls[0].attributes[kSecValueData as String] as? Data == Data("fixture password".utf8))
        #expect(state.calls[1].query[kSecReturnData as String] as? Bool == true)
        #expect(state.calls[1].query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }
}

@Test nonisolated func syncedPasswordAddsOnlyWhenNoPriorItemExists() {
    let fixture = CredentialKeychainFixture()
    fixture.state.withLock { $0.updates = [errSecItemNotFound] }
    #expect(fixture.store().save(password: "new password", for: credentialConnection()))
    fixture.state.withLock { state in
        #expect(state.calls.map(\.name) == ["update", "add"])
        #expect(state.calls[1].query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(state.calls[1].query[kSecValueData as String] as? Data == Data("new password".utf8))
        #expect(state.calls[1].query[kSecAttrSynchronizable as String] as? Bool == true)
    }
}

@Test nonisolated func syncedPasswordConcurrentInsertRetriesUpdateWithoutDeletingAnything() {
    for finalStatus in [errSecSuccess, errSecInteractionNotAllowed] {
        let fixture = CredentialKeychainFixture()
        fixture.state.withLock {
            $0.updates = [errSecItemNotFound, finalStatus]
            $0.add = errSecDuplicateItem
        }
        #expect(fixture.store().save(password: "new password", for: credentialConnection()) == (finalStatus == errSecSuccess))
        fixture.state.withLock { #expect($0.calls.map(\.name) == ["update", "add", "update"]) }
    }
}

@Test nonisolated func syncedPasswordReportsSecureStorageErrorsWithoutDestructiveFallback() {
    for failure in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecAuthFailed] {
        let fixture = CredentialKeychainFixture()
        fixture.state.withLock { $0.updates = [failure] }
        #expect(!fixture.store().save(password: "new password", for: credentialConnection()))
        fixture.state.withLock { #expect($0.calls.map(\.name) == ["update"]) }
    }
    let fixture = CredentialKeychainFixture()
    fixture.state.withLock { $0.updates = [errSecItemNotFound]; $0.add = errSecMissingEntitlement }
    #expect(!fixture.store().save(password: "new password", for: credentialConnection()))
    fixture.state.withLock { #expect($0.calls.map(\.name) == ["update", "add"]) }
}

@Test nonisolated func syncedPasswordDeletionIsIdempotentButReportsFailure() {
    for status in [errSecSuccess, errSecItemNotFound, errSecInteractionNotAllowed] {
        let fixture = CredentialKeychainFixture()
        fixture.state.withLock { $0.delete = status }
        #expect(fixture.store().delete(for: credentialConnection()) == (status != errSecInteractionNotAllowed))
        fixture.state.withLock { #expect($0.calls.map(\.name) == ["delete"]) }
    }
}

@Test nonisolated func syncedPasswordOriginAndAccountCannotLeakAcrossServers() throws {
    let fixture = CredentialKeychainFixture()
    let connections = [
        credentialConnection("https://nas.example", account: "listener"),
        credentialConnection("https://NAS.EXAMPLE.:443/path", account: "listener"),
        credentialConnection("http://nas.example:443", account: "listener"),
        credentialConnection("https://nas.example:5001", account: "listener"),
        credentialConnection("https://other.example", account: "listener"),
        credentialConnection("https://nas.example", account: "Listener"),
        credentialConnection("https://nas.example", account: "other"),
        credentialConnection("https://nas.example", account: "listener|https://other.example:443"),
    ]
    for connection in connections { _ = fixture.store().password(for: connection) }
    try fixture.state.withLock { state in
        let keys = try state.calls.map { try #require($0.query[kSecAttrAccount as String] as? String) }
        #expect(keys[0] == keys[1])
        #expect(Set(keys).count == connections.count - 1)
        let data = try #require(Data(base64Encoded: keys[0]))
        #expect(try JSONDecoder().decode([String].self, from: data) == ["https://nas.example:443", "listener"])
    }
}

@Test nonisolated func syncedPasswordDoesNotUseInvalidOriginsBlankAccountsOrMissingEntitlements() {
    for connection in [
        credentialConnection("ftp://nas.example"),
        credentialConnection("https://other@nas.example"),
        credentialConnection("https://nas.example/#fragment"),
        credentialConnection(account: " \n"),
    ] {
        let fixture = CredentialKeychainFixture()
        #expect(!fixture.store().save(password: "fixture password", for: connection))
        #expect(fixture.store().password(for: connection) == nil)
        #expect(!fixture.store().delete(for: connection))
        fixture.state.withLock { #expect($0.calls.isEmpty) }
    }
    for group in [nil, "", "$(AppIdentifierPrefix)com.samuelvoltolini.gumbo"] as [String?] {
        let fixture = CredentialKeychainFixture()
        #expect(!fixture.store(group: group).save(password: "fixture password", for: credentialConnection()))
        #expect(fixture.store(group: group).password(for: credentialConnection()) == nil)
        #expect(!fixture.store(group: group).delete(for: credentialConnection()))
        fixture.state.withLock { #expect($0.calls.isEmpty) }
    }
}

@Test nonisolated func syncedPasswordUnsupportedPlatformsNeverTouchAnyKeychain() {
    let fixture = CredentialKeychainFixture()
    let store = fixture.store(supported: false)
    #expect(!store.save(password: "fixture password", for: credentialConnection()))
    #expect(store.password(for: credentialConnection()) == nil)
    #expect(!store.delete(for: credentialConnection()))
    fixture.state.withLock { #expect($0.calls.isEmpty) }
}

@Test nonisolated func syncedPasswordUnreadableOrEmptyDataDoesNotProduceCredentials() {
    for result: (OSStatus, Data?) in [
        (errSecItemNotFound, nil), (errSecInteractionNotAllowed, Data("secret".utf8)),
        (errSecSuccess, nil), (errSecSuccess, Data()), (errSecSuccess, Data([0xff])),
    ] {
        let fixture = CredentialKeychainFixture()
        fixture.state.withLock { $0.copy = result }
        #expect(fixture.store().password(for: credentialConnection()) == nil)
    }
    let fixture = CredentialKeychainFixture()
    #expect(!fixture.store().save(password: "", for: credentialConnection()))
    fixture.state.withLock { #expect($0.calls.isEmpty) }
}
