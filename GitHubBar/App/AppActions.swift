import AppKit
import GitHubBarCore

@MainActor
struct AppActions {
    let openSettings: () -> Void
    let openAbout: () -> Void
    let openWorkspace: (BoardSubject?) -> Void
    let openSearch: () -> Void

    init(
        openSettings: @escaping () -> Void = {},
        openAbout: @escaping () -> Void = { NSApp.orderFrontStandardAboutPanel(nil) },
        openWorkspace: @escaping (BoardSubject?) -> Void = { _ in },
        openSearch: @escaping () -> Void = {}
    ) {
        self.openSettings = openSettings
        self.openAbout = openAbout
        self.openWorkspace = openWorkspace
        self.openSearch = openSearch
    }
}
