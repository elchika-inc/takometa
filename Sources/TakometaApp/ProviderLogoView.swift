import AppKit
import OSLog
import SwiftUI
import TakometaCore

struct ProviderLogoView: View {
    let provider: ProviderID

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Takometa",
        category: "ProviderLogo")

    static var claudeLogoURL: URL? {
        Bundle.module.url(forResource: "claude-logo", withExtension: "svg")
    }

    private static let claudeLogoImage: NSImage? = {
        guard let url = claudeLogoURL, let image = NSImage(contentsOf: url) else {
            logger.error("Claude プロバイダロゴの読み込みに失敗しました")
            return nil
        }
        return image
    }()

    @ViewBuilder
    var body: some View {
        switch provider {
        case .codex:
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
        case .claude:
            if let image = Self.claudeLogoImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            }
        }
    }
}
