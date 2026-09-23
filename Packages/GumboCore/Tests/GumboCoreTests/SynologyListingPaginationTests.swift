import Foundation
import Testing
@testable import GumboCore

private actor ListingPageTransport {
    private let pages: [SynologyFileList]
    private(set) var offsets: [Int] = []

    init(_ pages: [SynologyFileList]) { self.pages = pages }

    func request(_ url: URL) throws -> SynologyFileList {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? -1
        let index = offsets.count
        offsets.append(offset)
        guard pages.indices.contains(index) else { throw SynologyListingError.incomplete }
        return pages[index]
    }
}

private nonisolated func listingPage(_ range: Range<Int>, total: Int? = nil, offset: Int? = nil) -> SynologyFileList {
    SynologyFileList(files: range.map {
        SynologyFileEntry(isdir: false, name: "\($0).flac", path: "/music/\($0).flac", additional: nil)
    }, offset: offset, total: total)
}

private nonisolated func listingDrive(_ transport: ListingPageTransport) -> SynologyDrive {
    let session = DSMSession(
        baseURL: URL(string: "https://pagination-test.invalid")!, sid: "fixture",
        apis: ["SYNO.FileStation.List": SynologyAPIDescriptor(path: "entry.cgi", minVersion: 1, maxVersion: 2)]
    )
    return SynologyDrive(session: session, displayName: "Pagination fixture", renewal: nil) { url in
        try await transport.request(url)
    }
}

@Suite struct SynologyListingPaginationTests {
    @Test func absentTotalContinuesPastTheFirstFullPage() async throws {
        let transport = ListingPageTransport([listingPage(0..<1000), listingPage(1000..<1002)])
        let files = try await listingDrive(transport).list("/music")
        #expect(files.count == 1002)
        #expect(files.last?.path == "/music/1001.flac")
        #expect(await transport.offsets == [0, 1000])
    }

    @Test func absentTotalChecksAfterAnExactlyFullLastPage() async throws {
        let transport = ListingPageTransport([listingPage(0..<1000), listingPage(1000..<1000)])
        #expect(try await listingDrive(transport).list("/music").count == 1000)
        #expect(await transport.offsets == [0, 1000])
    }

    @Test(arguments: [false, true])
    func emptyFolderIsACompleteListing(withTotal: Bool) async throws {
        let transport = ListingPageTransport([listingPage(0..<0, total: withTotal ? 0 : nil)])
        #expect(try await listingDrive(transport).list("/music").isEmpty)
        #expect(await transport.offsets == [0])
    }

    @Test func advertisedTotalRequiresEveryEntryEvenWithShortPages() async throws {
        // Some DSM versions cap each page below the requested limit. An advertised total wins.
        let transport = ListingPageTransport([
            listingPage(0..<2, total: 3, offset: 0), listingPage(2..<3, total: 3, offset: 2),
        ])
        #expect(try await listingDrive(transport).list("/music").count == 3)
        #expect(await transport.offsets == [0, 2])
    }

    @Test func advertisedTotalIsRetainedWhenALaterPageOmitsIt() async throws {
        let transport = ListingPageTransport([
            listingPage(0..<2, total: 4), listingPage(2..<3), listingPage(3..<4),
        ])
        #expect(try await listingDrive(transport).list("/music").count == 4)
        #expect(await transport.offsets == [0, 2, 3])
    }

    @Test func earlyEmptyPageDoesNotPublishFilesAsMissing() async throws {
        let transport = ListingPageTransport([
            listingPage(0..<1000, total: 1002), listingPage(1000..<1000, total: 1002),
        ])
        await #expect(throws: SynologyListingError.incomplete) {
            try await listingDrive(transport).list("/music")
        }
        // Inconsistent pagination is not retried with weaker compatibility parameters.
        #expect(await transport.offsets == [0, 1000])
    }

    @Test func changingTotalRejectsTheWholeListing() async throws {
        let transport = ListingPageTransport([listingPage(0..<2, total: 4), listingPage(2..<4, total: 5)])
        await #expect(throws: SynologyListingError.incomplete) {
            try await listingDrive(transport).list("/music")
        }
        #expect(await transport.offsets == [0, 2])
    }

    @Test func repeatedPageIsRejectedWithoutAnInfiniteLoop() async throws {
        let transport = ListingPageTransport([listingPage(0..<1000), listingPage(0..<1000)])
        await #expect(throws: SynologyListingError.incomplete) {
            try await listingDrive(transport).list("/music")
        }
        #expect(await transport.offsets == [0, 1000])
    }

    @Test func inconsistentPageMetadataIsRejected() async throws {
        let duplicate = listingPage(0..<1).files[0]
        let invalidPages = [
            listingPage(0..<0, total: 2),
            listingPage(0..<1, total: -1),
            listingPage(0..<2, total: 1),
            listingPage(0..<1, total: 1, offset: 1),
            listingPage(0..<1001),
            SynologyFileList(files: [duplicate, duplicate], offset: 0, total: 2),
        ]
        for page in invalidPages {
            let transport = ListingPageTransport([page])
            await #expect(throws: SynologyListingError.incomplete) {
                try await listingDrive(transport).list("/music")
            }
            #expect(await transport.offsets == [0])
        }
    }
}
