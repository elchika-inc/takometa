import Foundation
import OSLog

/// 履歴の読み書き。
///
/// **`Sendable` にしない**（N-14）。init で1度 `load()` して以降メモリを正とする＝
/// 可変状態を持つため、`Sendable` 準拠だと Swift 6 でコンパイルエラーになる。
/// `UsageStore` も view もメインスレッドで動くので `@MainActor` 隔離のコストは無い。
@MainActor
public protocol UsageHistoryStoring {
    /// `at` 昇順で返す（N-13）
    func points(for key: String) -> [HistoryPoint]
    func append(_ point: HistoryPoint, key: String, now: Date) throws
}

/// ファイル形式のエンコード。**テストからも同じ経路を使う**ため切り出す
/// （テストが独自にエンコードすると、実ファイルと違う形を測ってしまう）
enum HistoryFileCodec {
    static func encode(_ value: [String: [HistoryPoint]]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// 保持の上限。窓ごとに適用する
enum HistoryLimits {
    static let retention: TimeInterval = 48 * 3600
    static let maximumPoints = 1000
}

/// 書き込み後の保持上限と全窓剪定。入力を変更せず、新しい辞書を返す純関数。
enum HistoryPruning {
    static func applyingLimits(
        to history: [String: [HistoryPoint]], writtenKey: String, now: Date
    ) -> [String: [HistoryPoint]] {
        var result = history

        // まず今回書き込んだ窓の点数上限を適用する
        if var points = result[writtenKey], points.count > HistoryLimits.maximumPoints {
            points.removeFirst(points.count - HistoryLimits.maximumPoints)
            result[writtenKey] = points
        }

        // 書き込みが来ない窓も含め、全窓を48時間で剪定する
        let cutoff = now.addingTimeInterval(-HistoryLimits.retention)
        for (key, points) in result {
            let kept = points.filter { $0.at >= cutoff }
            if kept.isEmpty {
                result.removeValue(forKey: key)
            } else if kept.count != points.count {
                result[key] = kept
            }
        }
        return result
    }
}

/// ディスクへ永続化する実装。
///
/// **init で1度だけ `load()` し、以降はメモリを正とする**（N-14）。
/// 読み出しのたびにデコードすると、上限まで溜まったファイルで 35 ms かかり
/// popover の body 評価がフレームを落とす（実測）。
@MainActor
public final class FileUsageHistoryStore: UsageHistoryStoring {
    private let directory: URL
    private var cache: [String: [HistoryPoint]]
    private let warningHandler: (String) -> Void

    public convenience init(directory: URL? = nil) {
        let logger = Logger(subsystem: "Takometa", category: "UsageHistory")
        self.init(directory: directory) { message in
            logger.warning("\(message, privacy: .public)")
        }
    }

    /// N-10の固定警告を実行テストするためのCore内部注入口。
    init(directory: URL? = nil, warningHandler: @escaping (String) -> Void) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Takometa", isDirectory: true)
        self.warningHandler = warningHandler
        self.cache = [:]
        self.cache = loadFromDisk()
    }

    public func points(for key: String) -> [HistoryPoint] {
        cache[key] ?? []
    }

    public func append(_ point: HistoryPoint, key: String, now: Date) throws {
        var points = cache[key] ?? []
        // 昇順を保つ（N-13）。通常は末尾追加で済む
        if let last = points.last, point.at < last.at {
            let index = points.firstIndex { $0.at > point.at } ?? points.endIndex
            points.insert(point, at: index)
        } else {
            points.append(point)
        }
        cache[key] = points
        cache = HistoryPruning.applyingLimits(to: cache, writtenKey: key, now: now)
        try writeToDisk()
    }

    private func loadFromDisk() -> [String: [HistoryPoint]] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            // 黙って握りつぶさない。パス・例外メッセージは出さない（N-10）
            warningHandler("使用量履歴ファイルを読み取れませんでした。空として扱います")
            return [:]
        }
        guard let decoded = try? JSONDecoder()
            .decode([String: [HistoryPoint]].self, from: data)
        else {
            // 黙って握りつぶさない。パス・例外メッセージは出さない（N-10）
            warningHandler("使用量履歴を読めませんでした。空として扱います")
            return [:]
        }
        let isAscending = decoded.values.allSatisfy { points in
            zip(points, points.dropFirst()).allSatisfy { pair in
                pair.0.at <= pair.1.at
            }
        }
        guard isAscending else {
            warningHandler("使用量履歴の順序が不正です。空として扱います")
            return [:]
        }
        return decoded
    }

    private func writeToDisk() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try HistoryFileCodec.encode(cache).write(to: fileURL, options: .atomic)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("usage-history.json", isDirectory: false)
    }
}

/// どこにも書かない実装。`UsageStore.init` の既定値（N-15）。
///
/// **既定を `nil`（記録しない）にしない。** 記録経路そのものが無効になると、
/// アプリ側の注入漏れで機能が丸ごと死んでもテストは全部緑になり、
/// UI でも「機能が死んだ状態」と「正常な起動直後」が視覚的に同一になる。
@MainActor
public final class InMemoryUsageHistoryStore: UsageHistoryStoring {
    private var storage: [String: [HistoryPoint]] = [:]

    public init() {}

    public func points(for key: String) -> [HistoryPoint] {
        storage[key] ?? []
    }

    public func append(_ point: HistoryPoint, key: String, now: Date) throws {
        var points = storage[key] ?? []
        if let last = points.last, point.at < last.at {
            let index = points.firstIndex { $0.at > point.at } ?? points.endIndex
            points.insert(point, at: index)
        } else {
            points.append(point)
        }
        storage[key] = points
        storage = HistoryPruning.applyingLimits(to: storage, writtenKey: key, now: now)
    }
}
