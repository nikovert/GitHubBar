import AppKit
import GitHubBarCore

@MainActor
final class StatusItemController: NSObject {
    let appModel: AppModel
    let actions: AppActions
    let workspaceModel: WorkspaceModel
    let avatarImageCache: AvatarImageCache
    let statusItem: NSStatusItem
    let statusMenu = NSMenu()
    var isStatusMenuOpen = false
    var highlightedStatusMenuItem: NSMenuItem?
    var statusMenuKeyMonitor: Any?
    var registeredShortcut: GitHubBarShortcut?
    var pendingRepositoryScope: RepositoryScope?
    private var avatarCacheAccountLogin: String?
    private let searchModel: PRSearchModel?
    private let reviewAgentModel: ReviewAgentModel?

    init(
        appModel: AppModel,
        actions: AppActions = AppActions(),
        workspaceModel: WorkspaceModel,
        avatarImageCache: AvatarImageCache,
        searchModel: PRSearchModel? = nil,
        reviewAgentModel: ReviewAgentModel? = nil
    ) {
        self.appModel = appModel
        self.actions = actions
        self.workspaceModel = workspaceModel
        self.avatarImageCache = avatarImageCache
        self.searchModel = searchModel
        self.reviewAgentModel = reviewAgentModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        apply(appModel.state)

        appModel.onStateChange = { [weak self] state in
            self?.apply(state)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        configureStatusMenu()
    }

    private func apply(_ state: AppPresentationState) {
        workspaceModel.updateWorkload(state)
        searchModel?.updateWorkload(state)
        let reviewLogin = connectedAccountLogin(in: state)
        Task { [weak reviewAgentModel] in await reviewAgentModel?.updateMonitoredAccount(reviewLogin) }
        guard let button = statusItem.button else { return }
        let accountLogin = connectedAccountLogin(in: state)
        if avatarCacheAccountLogin != accountLogin {
            avatarImageCache.removeAll()
            avatarCacheAccountLogin = accountLogin
        }
        let avatarURLs = avatarURLs(in: state)
        Task {
            await avatarImageCache.preload(avatarURLs)
        }
        button.image = StatusIconRenderer.image(reviewCount: state.reviewCount)
        button.setAccessibilityTitle("GitHubBar. \(state.reviewCountAccessibilityLabel).")
        button.toolTip = "GitHubBar — \(state.reviewCountAccessibilityLabel)"
        updateStatusMenu(for: state)
    }

    private func avatarURLs(in state: AppPresentationState) -> [URL] {
        (state.needsYourReview + state.authoredPullRequests).flatMap { pullRequest in
            var urls = pullRequest.reviewers.compactMap(\.avatarURL)
            if let authorURL = pullRequest.author?.avatarURL {
                urls.append(authorURL)
            }
            return urls
        }
    }

    private func connectedAccountLogin(in state: AppPresentationState) -> String? {
        guard case let .connected(login, _) = state.accountConnection else { return nil }
        return login
    }

    func showMenu() {
        let avatarURLs = avatarURLs(in: appModel.state)
        Task {
            await avatarImageCache.preload(avatarURLs)
        }
        statusItem.button?.performClick(nil)
    }

    func toggleMenu() {
        if isStatusMenuOpen {
            statusMenu.cancelTracking()
        } else {
            showMenu()
        }
    }

    func setRegisteredShortcut(_ shortcut: GitHubBarShortcut) {
        registeredShortcut = shortcut
        rebuildStatusMenu()
    }
}
