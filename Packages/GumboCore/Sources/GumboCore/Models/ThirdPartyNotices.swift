import Foundation

public nonisolated enum ThirdPartyNotices {
    public static var text: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "Open source notices are available with Gumbo's source code." }
        return value
    }
}
