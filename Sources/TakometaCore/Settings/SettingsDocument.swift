public struct SettingsDocument: Sendable, Equatable {
    public var version: Int
    public var displayMode: DisplayMode
    public var providerOrder: [String]
    public var menuBarLineCount: MenuBarLineCount
    public var showsFloatingPanel: Bool
    public var providers: [String: ProviderSettings]

    public init(
        version: Int = 1,
        displayMode: DisplayMode = .full,
        providerOrder: [String] = [ProviderID.codex.rawValue, ProviderID.claude.rawValue],
        menuBarLineCount: MenuBarLineCount = .one,
        showsFloatingPanel: Bool = false,
        providers: [String: ProviderSettings] = [
            ProviderID.codex.rawValue: ProviderSettings(),
            ProviderID.claude.rawValue: ProviderSettings(),
        ]
    ) {
        self.version = version
        self.displayMode = displayMode
        self.providerOrder = providerOrder
        self.menuBarLineCount = menuBarLineCount
        self.showsFloatingPanel = showsFloatingPanel
        self.providers = providers
    }
}
