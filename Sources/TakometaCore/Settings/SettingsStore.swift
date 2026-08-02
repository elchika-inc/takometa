import Foundation
import Observation

@Observable @MainActor
public final class SettingsStore {
    public private(set) var displayMode: DisplayMode
    public private(set) var menuBarLineCount: MenuBarLineCount
    public private(set) var showsFloatingPanel: Bool
    public private(set) var providerOrder: [String]
    public private(set) var providers: [String: ProviderSettings]
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var rootObject: [String: Any]
    @ObservationIgnored private var isReadOnly: Bool

    private static let fileName = "provider-settings.json"
    private static let knownProviderIDs = [
        ProviderID.codex.rawValue,
        ProviderID.claude.rawValue,
    ]

    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Takometa", isDirectory: true)
        displayMode = .full
        menuBarLineCount = .one
        showsFloatingPanel = false
        providerOrder = Self.knownProviderIDs
        providers = Self.defaultProviders()
        lastErrorDescription = nil
        rootObject = [:]
        isReadOnly = false

        let fileURL = self.directory.appendingPathComponent(Self.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            apply(NotificationSettingsLoader.migrate(from: defaults))
            rootObject = Self.makeRootObject(
                displayMode: displayMode,
                providerOrder: providerOrder,
                menuBarLineCount: menuBarLineCount,
                showsFloatingPanel: showsFloatingPanel,
                providers: providers)
            save()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            enterReadOnlyMode("設定ファイルを読み取れないため保存を停止しました: \(error.localizedDescription)")
            return
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            regenerateDefaults()
            return
        }

        guard let object = parsed as? [String: Any] else {
            regenerateDefaults()
            return
        }

        rootObject = object
        apply(Self.decodeDocument(from: object))

        if let rawVersion = object["version"] {
            guard let version = Self.integer(from: rawVersion), version == 1 else {
                enterReadOnlyMode("未対応の設定ファイルversionのため保存を停止しました")
                return
            }
        }
    }

    public func update(provider id: String, _ mutate: (inout ProviderSettings) -> Void) {
        guard ProviderID(rawValue: id) != nil, var settings = providers[id] else { return }
        mutate(&settings)
        providers[id] = settings
        save()
    }

    public func updateDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        save()
    }

    public func updateMenuBarLineCount(_ count: MenuBarLineCount) {
        menuBarLineCount = count
        save()
    }

    public func updateShowsFloatingPanel(_ shows: Bool) {
        showsFloatingPanel = shows
        save()
    }

    public func updateProviderOrder(_ newOrder: [String]) {
        providerOrder = Self.normalizeProviderOrder(
            newOrder,
            providerIDs: Set(providers.keys))
        save()
    }

    public func updateWindowKindOrder(
        provider id: String,
        visibleReordered: [WindowKindCategory]
    ) {
        guard let current = providers[id]?.windowKindOrder else { return }
        let reflected = WindowKindOrdering.applyingVisibleReorder(
            full: current, visibleReordered: visibleReordered)
        update(provider: id) {
            $0.windowKindOrder = WindowKindCategory.normalizedOrder(reflected.map(\.rawValue))
        }
    }

    private func apply(_ document: SettingsDocument) {
        displayMode = document.displayMode
        menuBarLineCount = document.menuBarLineCount
        showsFloatingPanel = document.showsFloatingPanel
        providers = document.providers
        providerOrder = document.providerOrder
    }

    private func regenerateDefaults() {
        apply(SettingsDocument())
        rootObject = Self.makeRootObject(
            displayMode: displayMode,
            providerOrder: providerOrder,
            menuBarLineCount: menuBarLineCount,
            showsFloatingPanel: showsFloatingPanel,
            providers: providers)
        isReadOnly = false
        save()
    }

    private func enterReadOnlyMode(_ message: String) {
        isReadOnly = true
        lastErrorDescription = message
    }

    private func save() {
        guard !isReadOnly else { return }

        var object = rootObject
        object["version"] = 1
        object["displayMode"] = displayMode.rawValue
        object["menuBarLineCount"] = menuBarLineCount.rawValue
        object["showsFloatingPanel"] = showsFloatingPanel
        object["providerOrder"] = providerOrder

        var rawProviders = object["providers"] as? [String: Any] ?? [:]
        for id in Self.knownProviderIDs {
            guard let settings = providers[id] else { continue }
            var rawSettings = rawProviders[id] as? [String: Any] ?? [:]
            Self.replaceKnownFields(in: &rawSettings, with: settings)
            rawProviders[id] = rawSettings
        }
        object["providers"] = rawProviders

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: directory.appendingPathComponent(Self.fileName, isDirectory: false),
                options: .atomic)
            rootObject = object
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = "設定ファイルを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private static func decodeDocument(from object: [String: Any]) -> SettingsDocument {
        let mode = DisplayMode.fromPersistedValue(object["displayMode"] as? String)
        let lineCount = (object["menuBarLineCount"] as? String)
            .flatMap(MenuBarLineCount.init(rawValue:)) ?? .one
        let showsPanel = bool(from: object["showsFloatingPanel"]) ?? false
        let rawProviders = object["providers"] as? [String: Any] ?? [:]
        var decodedProviders: [String: ProviderSettings] = [:]

        for (id, rawValue) in rawProviders {
            guard let rawSettings = rawValue as? [String: Any] else { continue }
            decodedProviders[id] = decodeProviderSettings(from: rawSettings)
        }
        for id in knownProviderIDs where decodedProviders[id] == nil {
            decodedProviders[id] = ProviderSettings()
        }

        let rawOrder: [String]
        if let values = object["providerOrder"] as? [Any],
           values.allSatisfy({ $0 is String })
        {
            rawOrder = values.compactMap { $0 as? String }
        } else {
            rawOrder = knownProviderIDs
        }

        return SettingsDocument(
            version: integer(from: object["version"]) ?? 1,
            displayMode: mode,
            providerOrder: normalizeProviderOrder(
                rawOrder,
                providerIDs: Set(decodedProviders.keys)),
            menuBarLineCount: lineCount,
            showsFloatingPanel: showsPanel,
            providers: decodedProviders)
    }

    private static func normalizeProviderOrder(
        _ order: [String],
        providerIDs: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var normalizedOrder = order.filter { id in
            guard providerIDs.contains(id), seen.insert(id).inserted else { return false }
            return true
        }
        for id in knownProviderIDs where seen.insert(id).inserted {
            normalizedOrder.append(id)
        }
        let unknownIDs = providerIDs
            .filter { !knownProviderIDs.contains($0) && !seen.contains($0) }
            .sorted()
        normalizedOrder.append(contentsOf: unknownIDs)
        return normalizedOrder
    }

    private static func decodeProviderSettings(from object: [String: Any]) -> ProviderSettings {
        let defaults = ProviderSettings()
        return ProviderSettings(
            show: bool(from: object["show"]) ?? defaults.show,
            showSession: bool(from: object["showSession"]) ?? defaults.showSession,
            showWeekly: bool(from: object["showWeekly"]) ?? defaults.showWeekly,
            showModel: bool(from: object["showModel"]) ?? defaults.showModel,
            notificationsEnabled: bool(from: object["notificationsEnabled"])
                ?? defaults.notificationsEnabled,
            usageThreshold: double(from: object["usageThreshold"]) ?? defaults.usageThreshold,
            dailyEnabled: bool(from: object["dailyEnabled"]) ?? defaults.dailyEnabled,
            dailyThreshold: double(from: object["dailyThreshold"]) ?? defaults.dailyThreshold,
            label: string(from: object["label"]) ?? defaults.label,
            windowKindOrder: WindowKindCategory.normalizedOrder(
                stringArray(from: object["windowKindOrder"])))
    }

    private static func replaceKnownFields(
        in object: inout [String: Any],
        with settings: ProviderSettings
    ) {
        object["show"] = settings.show
        object["showSession"] = settings.showSession
        object["showWeekly"] = settings.showWeekly
        object["showModel"] = settings.showModel
        object["notificationsEnabled"] = settings.notificationsEnabled
        object["usageThreshold"] = settings.usageThreshold
        object["dailyEnabled"] = settings.dailyEnabled
        object["dailyThreshold"] = settings.dailyThreshold
        object["label"] = settings.label
        object["windowKindOrder"] = settings.windowKindOrder.map(\.rawValue)
    }

    private static func makeRootObject(
        displayMode: DisplayMode,
        providerOrder: [String],
        menuBarLineCount: MenuBarLineCount,
        showsFloatingPanel: Bool,
        providers: [String: ProviderSettings]
    ) -> [String: Any] {
        var rawProviders: [String: Any] = [:]
        for (id, settings) in providers {
            var rawSettings: [String: Any] = [:]
            replaceKnownFields(in: &rawSettings, with: settings)
            rawProviders[id] = rawSettings
        }
        return [
            "version": 1,
            "displayMode": displayMode.rawValue,
            "providerOrder": providerOrder,
            "menuBarLineCount": menuBarLineCount.rawValue,
            "showsFloatingPanel": showsFloatingPanel,
            "providers": rawProviders,
        ]
    }

    private static func defaultProviders() -> [String: ProviderSettings] {
        Dictionary(uniqueKeysWithValues: knownProviderIDs.map { ($0, ProviderSettings()) })
    }

    private static func bool(from value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func double(from value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func string(from value: Any?) -> String? {
        value as? String
    }

    private static func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [Any], values.allSatisfy({ $0 is String }) else { return [] }
        return values.compactMap { $0 as? String }
    }

    private static func integer(from value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded() == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max)
        else { return nil }
        return Int(doubleValue)
    }
}
