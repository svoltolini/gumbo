import SwiftUI
import WidgetKit

@main
struct GumboWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GumboHomeWidget()
        RediscoverWidget()
        DownloadsWidget()
        PlaylistsWidget()
        DownloadLiveActivity()
    }
}
