import GumboCore
import SwiftUI

struct ThirdPartyNoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Link("Library source and build instructions", destination: URL(string: "https://github.com/svoltolini/gumbo/tree/main/Packages/GumboSMB")!)
                Text(ThirdPartyNotices.text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("Open Source Licenses")
    }
}
