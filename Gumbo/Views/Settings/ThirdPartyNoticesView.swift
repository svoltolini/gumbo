import GumboCore
import SwiftUI

struct ThirdPartyNoticesView: View {
    private static let sourceURL = "https://github.com/svoltolini/gumbo/tree/main/Packages/GumboSMB"

    #if os(tvOS)
    /// The notices one paragraph at a time: a television scroll view only moves as focus moves
    /// between paragraphs, so a single block of text could not be read past its first screen.
    private static let paragraphs: [String] = {
        var paragraphs: [String] = []
        var lines: [String] = []
        for line in ThirdPartyNotices.text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
                lines = []
            } else {
                lines.append(line)
            }
        }
        if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
        return paragraphs
    }()
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(tvOS)
                Text("Find the library source and build instructions at \(Self.sourceURL) on your phone or computer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
                ForEach(Self.paragraphs.indices, id: \.self) { index in
                    Text(Self.paragraphs[index])
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusable()
                }
                #else
                Link("Library source and build instructions", destination: URL(string: Self.sourceURL)!)
                Text(ThirdPartyNotices.text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                #endif
            }
            .padding()
        }
        .navigationTitle("Open Source Licenses")
    }
}
