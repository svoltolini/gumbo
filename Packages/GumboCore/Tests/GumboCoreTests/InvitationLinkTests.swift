import Foundation
import Testing
@testable import GumboCore

@Test func invitationLinkWithoutSchemeIsAccepted() {
    let url = CloudSync.invitationURL(in: "www.icloud.com/share/0AbCdEf")
    #expect(url?.absoluteString == "https://www.icloud.com/share/0AbCdEf")
    #expect(CloudSync.invitationURL(in: "  icloud.com/share/0AbCdEf\n")?.host() == "icloud.com")
}

@Test func invitationLinkIsFoundInsideAMessage() {
    let url = CloudSync.invitationURL(in: "Join us! https://www.icloud.com/share/0AbCdEf#Gumbo see you")
    #expect(url?.path() == "/share/0AbCdEf")
    #expect(CloudSync.invitationURL(in: "Join: www.icloud.com/share/0AbCdEf") != nil)
}

@Test func nonInvitationTextIsRejected() {
    #expect(CloudSync.invitationURL(in: "") == nil)
    #expect(CloudSync.invitationURL(in: "hello") == nil)
    #expect(CloudSync.invitationURL(in: "https://example.com/share/0AbC") == nil)
    #expect(CloudSync.invitationURL(in: "https://www.icloud.com/photos/0AbC") == nil)
    #expect(CloudSync.invitationURL(in: "ftp://www.icloud.com/share/0AbC") == nil)
}
