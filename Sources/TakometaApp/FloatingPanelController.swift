import AppKit
import Observation
import SwiftUI
import TakometaCore

/// フローティングパネルを NSPanel で自前管理する。
///
/// SwiftUI の `Window` シーンを使わないのは意図的（Issue #11 の実測結果）。
/// `Window` シーンは通常アプリのウィンドウライフサイクルを前提にしており、
/// LSUIElement 常駐アプリの常時最前面パネルに必要な3性質を宣言的に制御できない。
/// 1. アクティベーション非依存の表示（openWindow は協調的アクティベーションに阻まれる）
/// 2. 全 Space・フルスクリーン上での表示（シーン機構が collectionBehavior を管理し、
///    表示後にパネルを order out する挙動を実測した）
/// 3. 「ユーザーが閉じた」と「アプリが終了する」の区別（onDisappear は両方で発火し、
///    終了時に開閉状態の保存値を破壊していた）
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let observeContentChanges: () -> Void
    private let makeContent: (FloatingPanelController) -> AnyView
    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private var isTerminating = false

    /// 位置・サイズの復元は AppKit の frame autosave に任せる（自前で持たない）
    private static let frameAutosaveName = "TakometaFloatingPanel"
    private static let contentSizeProposal = CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)

    init(
        settingsStore: SettingsStore,
        observeContentChanges: @escaping () -> Void = {},
        makeContent: @escaping (FloatingPanelController) -> AnyView
    ) {
        self.settingsStore = settingsStore
        self.observeContentChanges = observeContentChanges
        self.makeContent = makeContent
        super.init()
        observeContentSizeChanges()
        // 終了時の close は「ユーザーが閉じた」ではないので、設定へ書き戻さない。
        // selector ベースの observer は dealloc 時に自動解除されるため deinit 不要
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil)
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        refreshContentSize()
        // autosave が画面外の frame を復元することがある（ディスプレイ構成の変化や
        // 異常終了時の保存値）。はみ出したまま出すと一部しか見えないので画面内へ収める
        clampToVisibleScreen(panel)
        // 非アクティブな LSUIElement アプリからでも表示できる唯一の経路
        panel.orderFrontRegardless()
    }

    func hide() {
        // close() ではなく orderOut: delegate の windowWillClose を発火させず、
        // 「設定変更に追従して隠しただけ」と「ユーザーの閉操作」を区別する
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // ユーザーがタイトルバーの × で閉じたときだけ設定へ書き戻す。
        // アプリ終了に伴う close はユーザーの意思表示ではない
        guard !isTerminating else { return }
        panel = nil
        hosting = nil
        settingsStore.updateShowsFloatingPanel(false)
    }

    func refreshContentSize() {
        guard let panel, let hosting else { return }
        let fittingSize = hosting.sizeThatFits(in: Self.contentSizeProposal)
        guard fittingSize != panel.contentLayoutRect.size else { return }
        panel.setContentSize(fittingSize)
        clampToVisibleScreen(panel)
    }

    private func observeContentSizeChanges() {
        // AppKit 側でサイズ追従用の依存を明示的に追跡し、SwiftUI 側の描画更新とは責務を分離する。
        withObservationTracking {
            observeContentChanges()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshContentSize()
                self.observeContentSizeChanges()
            }
        }
    }

    // MARK: - Private

    private func clampToVisibleScreen(_ panel: NSPanel) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(
            max(frame.origin.x, visible.minX),
            max(visible.maxX - frame.width, visible.minX))
        frame.origin.y = min(
            max(frame.origin.y, visible.minY),
            max(visible.maxY - frame.height, visible.minY))
        if frame != panel.frame {
            panel.setFrame(frame, display: false)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        panel.title = "Takometa"
        panel.level = .floating
        // フルスクリーンアプリの Space でも表示する。これがないとパネルは
        // デスクトップの Space に取り残され、作業中に見えない（Issue #11）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 他アプリへフォーカスが移っても消えない（NSPanel の既定は true）
        panel.hidesOnDeactivate = false
        // 常時表示のパネルがキー入力を奪わないようにする
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: makeContent(self))
        // hosting にウィンドウの制約を触らせない。既定の sizingOptions のままだと
        // titled パネルで invalidateSafeAreaCornerInsets → 制約無効化 → レイアウト
        // の無限ループになり、AppKit が limit 超過（51回/サイクル）で例外を投げて
        // クラッシュする（実測: _postWindowNeedsUpdateConstraints で EXC_BREAKPOINT）
        hosting.sizingOptions = []
        self.hosting = hosting
        panel.contentViewController = hosting
        // sizingOptions=[] では複合 View の fittingSize が 0x0 になることがあるため、
        // 自動 sizing を戻さず sizeThatFits(in:) で手動測定する（単純な Text では再現しない）。
        panel.setContentSize(hosting.sizeThatFits(in: Self.contentSizeProposal))
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.center()
        }
        return panel
    }
}
