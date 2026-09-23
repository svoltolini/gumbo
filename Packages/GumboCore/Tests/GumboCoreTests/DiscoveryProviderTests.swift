import Foundation
import Network
import Testing
@testable import GumboCore

struct DiscoveryProviderTests {
    @Test(arguments: ["QNAP", "TrueNAS", "UGREEN", "DiskStation", "Mac mini"])
    func smbAdvertisementIsAlwaysAnSMBHint(name: String) throws {
        let server = try #require(DiscoveryService.server(name: name, type: "_smb._tcp.", txt: [:], host: "192.168.1.4", port: 445))
        #expect(server.providerKind == .smb)
        #expect(server.baseURL.scheme == "smb")
        #expect(server.baseURL.port == 445)
        #expect(server.provider == nil) // A share must be chosen before sign-in.
    }

    @Test func httpRequiresSynologyHintAndSuggestsHTTPS() throws {
        #expect(DiscoveryService.provider(type: "_http._tcp", name: "Office Printer", txt: [:]) == nil)
        let server = try #require(DiscoveryService.server(name: "DiskStation", type: "_http._tcp.", txt: [:], host: "nas.local", port: 5000))
        #expect(server.providerKind == .synology)
        #expect(server.baseURL.absoluteString == "https://nas.local:5001")
    }

    @Test func secureWebDAVPreservesFolderAndPort() throws {
        let server = try #require(DiscoveryService.server(name: "Music", type: "_webdavs._tcp.", txt: ["path": "/dav/My Music/"], host: "nas.local", port: 5006))
        #expect(server.providerKind == .webDAV)
        #expect(server.baseURL.absoluteString == "https://nas.local:5006/dav/My%20Music/")
        #expect(DiscoveryService.provider(type: "_webdav._tcp", name: "Music", txt: [:]) == nil)
    }

    @Test(arguments: ["https://elsewhere.example/", "//elsewhere.example/", "/../escape", "/folder/./track", "/folder\\track", "/bad\npath"])
    func untrustedWebDAVPathCannotOverrideDestination(path: String) {
        #expect(DiscoveryService.server(name: "Music", type: "_webdavs._tcp", txt: ["path": path], host: "nas.local", port: 443) == nil)
    }

    @Test func distinctProtocolHintsAtSameHostRemainDistinct() throws {
        let smb = try #require(DiscoveryService.server(name: "DiskStation", type: "_smb._tcp", txt: [:], host: "nas.local", port: 445))
        let dsm = try #require(DiscoveryService.server(name: "DiskStation", type: "_https._tcp", txt: [:], host: "nas.local", port: 5001))
        #expect(smb.id != dsm.id)
    }

    @Test func IPv6IsPreserved() throws {
        let server = try #require(DiscoveryService.server(name: "Music", type: "_smb._tcp", txt: [:], host: "[2001:db8::1]", port: 445))
        #expect(server.baseURL.absoluteString == "smb://[2001:db8::1]:445")
    }

    @Test func deniedLocalNetworkPermissionIsRecognised() {
        #expect(DiscoveryService.isPolicyDenied(.dns(DiscoveryService.policyDeniedCode)))
        #expect(!DiscoveryService.isPolicyDenied(.dns(-65563)))
        #expect(!DiscoveryService.isPolicyDenied(.posix(.ECONNREFUSED)))
    }
}
