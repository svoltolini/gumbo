import CloudKit
import Foundation
import Testing
@testable import GumboCore

@Test func transientCloudErrorsAreRetriedWithBackoff() {
    for code in [CKError.Code.zoneBusy, .requestRateLimited, .serviceUnavailable, .networkUnavailable, .networkFailure] {
        #expect(CloudSync.retryDelay(for: CKError(code), attempt: 0) == .seconds(5))
    }
    #expect(CloudSync.retryDelay(for: CKError(.zoneBusy), attempt: 2) == .seconds(20))
    #expect(CloudSync.retryDelay(for: CKError(.zoneBusy), attempt: 50) == .seconds(300))
}

@Test func cloudRetryHonoursTheServersWait() {
    let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 42.0])
    #expect(CloudSync.retryDelay(for: error, attempt: 3) == .seconds(42))
}

@Test func permanentCloudErrorsAreNotRetried() {
    #expect(CloudSync.retryDelay(for: CKError(.quotaExceeded), attempt: 0) == nil)
    #expect(CloudSync.retryDelay(for: CKError(.permissionFailure), attempt: 0) == nil)
    #expect(CloudSync.retryDelay(for: CancellationError(), attempt: 0) == nil)
}
