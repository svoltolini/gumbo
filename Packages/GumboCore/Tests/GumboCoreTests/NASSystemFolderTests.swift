import Foundation
import Testing
@testable import GumboCore

struct NASSystemFolderTests {
    @Test(arguments: ["#snapshot", "@eaDir", "#recycle", "@Recycle", "@Recently-Snapshot", ".snapshot", ".hidden"])
    func systemFoldersAreNotScanned(name: String) {
        #expect(RemoteDriveSupport.isSystemFolder(name))
    }

    @Test(arguments: ["Music", "#1 Hits", "@Home Recordings", "Snapshot", "recycle"])
    func musicFoldersAreScanned(name: String) {
        #expect(!RemoteDriveSupport.isSystemFolder(name))
    }

    @Test func serverErrorRepliesAreNotTakenForCovers() {
        #expect(!RemoteDriveSupport.mayBeImage(Data(#"{"error":{"code":105},"success":false}"#.utf8)))
        #expect(!RemoteDriveSupport.mayBeImage(Data("\n <html><body>Error</body></html>".utf8)))
        #expect(!RemoteDriveSupport.mayBeImage(Data()))
        #expect(RemoteDriveSupport.mayBeImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(RemoteDriveSupport.mayBeImage(Data([0x89, 0x50, 0x4E, 0x47])))
    }
}
