import Foundation

public struct SnapshotCache: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Takometa", isDirectory: true)
        }
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: snapshot.provider), options: .atomic)
    }

    public func load(provider: ProviderID) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: provider)) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// キャッシュの読み取り結果。「不在」と「読めない」を区別する。
    ///
    /// 既存の `load(provider:)` は両方を `nil` にするため、握りつぶしで0件化してしまう。
    /// 報告系の CLI では「まだ取得していない」と「壊れている」を呼び出し側が
    /// 区別できる必要がある。
    public enum SnapshotReadResult: Sendable, Equatable {
        case loaded(UsageSnapshot)
        case absent
        case unreadable
    }

    /// 不在と読み取り失敗を区別してスナップショットを読む。
    ///
    /// `fileExists` で事前確認せず `Data(contentsOf:)` のエラーで判定する（TOCTOU を避ける）。
    public func read(provider: ProviderID) -> SnapshotReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: provider))
        } catch CocoaError.fileReadNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            return .unreadable
        }
        // ファイル名と中身の provider が違うキャッシュは、別 provider の値を
        // 誤表示しないよう読み取り不能として扱う。
        guard snapshot.provider == provider else { return .unreadable }
        return .loaded(snapshot)
    }

    private func fileURL(for provider: ProviderID) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }
}
