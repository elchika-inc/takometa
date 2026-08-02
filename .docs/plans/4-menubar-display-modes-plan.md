# メニューバー表示モード再設計 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** メニューバー表示の3モードを「占有幅の段階」として再定義し、最小幅のアイコン表示を追加する。

**Architecture:** `DisplayMode` の3ケースの意味を1段ずつ下へずらす。`Full` は現行維持、`Balanced` は現 `compact` のロジック（プロバイダごとに最逼迫1枠）を引き継ぎ、`Compact` はゲージアイコンのみの新規実装とする。アイコンは `MenuBarColumns` と同じパターンで専用の値型 `MenuBarIcons` を `TakometaCore` に持ち、SF Symbols 名への写像は表示層が担う。既存の設定値は永続化文字列の写像で1段繰り上げ、利用者の見た目を変えない。

**Tech Stack:** Swift 6.2 / SwiftUI / XCTest / SwiftPM

**設計書:** [`4-menubar-display-modes-design.md`](4-menubar-display-modes-design.md) — 判断の根拠はすべてこちらにある。

## Global Constraints

- ビルドとテストにはフル Xcode 26.6 が必要。Command Line Tools のみでは `PreviewsMacros` が不足してビルドできない
- 検証コマンドは `swift build` と `swift test`。`;` や `&&` で連結せず個別に実行する
- `TakometaCore` は UI 詳細を持たない。SF Symbols 名は `TakometaApp` 側にのみ書く
- 値が取得できない場合に 0% を表示しない。`RateLimitWindow` を作らず unavailable として区別する
- エージェントは `main` へ直接コミットしない。本計画の実装は `feat/4-menubar-display-modes` ブランチで行う
- コミットメッセージは日本語の Conventional Commits 形式（既存履歴に準拠）

## 事前準備

- [ ] **設計書ブランチから実装ブランチを切る**

```bash
git checkout -b feat/4-menubar-display-modes
```

`docs/4-menubar-display-modes` に設計書のコミットが乗っている。そこから分岐する。

---

### Task 1: DisplayMode の永続化写像を移行対応にする

`DisplayMode` の意味が1段ずれるため、旧版が保存した文字列と新版の文字列を区別できるようにする。読み取り経路は2箇所あり、両方を1つの写像へ集約する。

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift:3-7`（`DisplayMode` の定義）
- Modify: `Sources/TakometaCore/Settings/SettingsStore.swift:174`
- Modify: `Sources/TakometaCore/Notification/NotificationSettingsLoader.swift:24-25`
- Test: `Tests/TakometaCoreTests/SettingsMigrationTests.swift`
- Test: `Tests/TakometaCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `DisplayMode.fromPersistedValue(_ raw: String?) -> DisplayMode`。以降のタスクは `DisplayMode` の3ケース（`.full` / `.balanced` / `.compact`）を case 名で参照する。rawValue はそれぞれ `"full"` / `"onePerProvider"` / `"icon"`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/TakometaCoreTests/SettingsMigrationTests.swift` のクラス内に追加する。**リテラル文字列を直接書くこと** — `DisplayMode.compact.rawValue` のようにシンボル経由で書くと rawValue の変更に追従してしまい、移行の回帰を検出できない。

```swift
func testLegacyDisplayModeStringsMigrateOneStepUp() {
    XCTAssertEqual(DisplayMode.fromPersistedValue("compact"), .balanced)
    XCTAssertEqual(DisplayMode.fromPersistedValue("balanced"), .full)
    XCTAssertEqual(DisplayMode.fromPersistedValue("full"), .full)
}

func testNewDisplayModeStringsRoundTrip() {
    XCTAssertEqual(DisplayMode.fromPersistedValue("onePerProvider"), .balanced)
    XCTAssertEqual(DisplayMode.fromPersistedValue("icon"), .compact)
}

func testUnknownAndMissingDisplayModeFallBackToFull() {
    XCTAssertEqual(DisplayMode.fromPersistedValue("unknown"), .full)
    XCTAssertEqual(DisplayMode.fromPersistedValue(nil), .full)
}

func testDisplayModeMigrationIsIdempotent() {
    for legacy in ["compact", "balanced", "full"] {
        let once = DisplayMode.fromPersistedValue(legacy)
        let twice = DisplayMode.fromPersistedValue(once.rawValue)
        XCTAssertEqual(once, twice, "\(legacy) の移行が冪等でない")
    }
}

func testMigrateFromUserDefaultsAppliesLegacyDisplayModeMapping() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("compact", forKey: NotificationSettingsLoader.displayModeKey)

    let document = NotificationSettingsLoader.migrate(from: defaults)

    XCTAssertEqual(document.displayMode, .balanced)
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
swift test --filter SettingsMigrationTests
```

期待: `fromPersistedValue` が存在せずコンパイルエラー。

- [ ] **Step 3: DisplayMode の rawValue を変え、写像を追加する**

`Sources/TakometaCore/Label/MenuBarLabelFormatter.swift` の先頭にある `DisplayMode` を差し替える。

```swift
public enum DisplayMode: String, Sendable, CaseIterable {
    case full                          // "full" ─ 意味不変
    // 以下2つは rawValue が case 名と異なる。旧版の同名の値と意味がずれたため、
    // 永続化層で新旧を区別できるようにする（設計書 §5.2）。
    case balanced = "onePerProvider"   // 旧 "balanced"（モデル枠1個）とは別物
    case compact = "icon"              // 旧 "compact"（最逼迫1枠）とは別物

    /// 永続化された文字列からモードを復元する。
    /// 旧版の値（"compact" = 最逼迫1枠 / "balanced" = モデル枠1個）は
    /// 新しい体系へ1段繰り上げて解釈する（設計書 §5.2 の表）。
    public static func fromPersistedValue(_ raw: String?) -> DisplayMode {
        switch raw {
        case DisplayMode.full.rawValue: return .full
        case DisplayMode.balanced.rawValue: return .balanced
        case DisplayMode.compact.rawValue: return .compact
        case "compact": return .balanced   // 旧版
        case "balanced": return .full      // 旧版（設計書 §5.4）
        default: return .full
        }
    }
}
```

- [ ] **Step 4: 読み取り経路2箇所を写像へ差し替える**

`Sources/TakometaCore/Settings/SettingsStore.swift:174` を変更する。

```swift
// 変更前
let mode = (object["displayMode"] as? String).flatMap(DisplayMode.init(rawValue:)) ?? .full
// 変更後
let mode = DisplayMode.fromPersistedValue(object["displayMode"] as? String)
```

`Sources/TakometaCore/Notification/NotificationSettingsLoader.swift:24-25` を変更する。

```swift
// 変更前
displayMode: defaults.string(forKey: displayModeKey)
    .flatMap(DisplayMode.init(rawValue:)) ?? .full,
// 変更後
displayMode: DisplayMode.fromPersistedValue(defaults.string(forKey: displayModeKey)),
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
swift test --filter SettingsMigrationTests
```

期待: PASS。

- [ ] **Step 6: JSON 経路の移行テストを追加する**

`Tests/TakometaCoreTests/SettingsStoreTests.swift` のクラス内に追加する。既存の `withTemporaryDirectory` / `writeJSON` / `makeStore` / `jsonObject(in:)` ヘルパーを使う。

**fixture は必ず `writeJSON` で書くこと。** `withTemporaryDirectory`（`:513`）は URL を返すだけでディレクトリの実体を作らない。実体を作るのは `writeData`（`:540`）で、ここが `createDirectory` と `settingsURL(in:)` の両方を解決している。直接 `Data.write` すると親ディレクトリがなく `ENOENT` になり、さらにファイル名を literal で持つと正本（`SettingsStore.fileName`、`:16`）から乖離してテストが黙って別ファイルを見る。

```swift
func testLegacyCompactInFileLoadsAsBalancedAndPersistsNewRawValue() throws {
    try withTemporaryDirectory { directory in
        try writeJSON("""
        {"version":1,"displayMode":"compact","providerOrder":["codex","claude"],"providers":{}}
        """, in: directory)

        let store = try makeStore(directory: directory)
        XCTAssertEqual(store.displayMode, .balanced)

        // 保存し直された値が新しい rawValue になっていること
        store.update(provider: "codex") { $0.usageThreshold = 80 }
        let saved = try jsonObject(in: directory)
        XCTAssertEqual(saved["displayMode"] as? String, "onePerProvider")

        // 再読込しても繰り上がらないこと
        let reloaded = try makeStore(directory: directory)
        XCTAssertEqual(reloaded.displayMode, .balanced)
    }
}
```

このテストが依拠している既存挙動（いずれも実測で確認済み）:

- `SettingsStore.save()`（`:143`）が `object["displayMode"] = displayMode.rawValue` を無条件に書くため、`update(provider:)` だけで displayMode も新 rawValue へ書き換わる。`updateDisplayMode` の明示呼び出しは不要
- `decodeDocument` は providers が空でも `knownProviderIDs` で既定値を補完するため `"providers":{}` で足りる

- [ ] **Step 6.5: 既存テストの期待値を新しい意味へ追随させる**

既存テストのうち、旧リテラル（`"compact"` / `"balanced"`）を書いて旧来の意味を期待しているものは、移行写像の導入で必ず落ちる。これらは displayMode の値そのものを検証対象にしておらず、設定ファイルの読み書き挙動（未対応 version での read-only、version 型不正、version 欠落、不正値のフォールバック、保存形式）を検証している。displayMode はその素材にすぎないため、**期待値を新しい意味へ追随させる。テストの意図は変えない**。

行番号は編集でずれるのでテスト関数名で特定すること。

| ファイル | テスト | 変更 |
|---|---|---|
| `SettingsStoreTests.swift` | `testUnknownVersionLoadsKnownValuesButInitAndUpdatesPreserveOriginalBytes` | `XCTAssertEqual(store.displayMode, .compact)` → `.balanced` |
| `SettingsStoreTests.swift` | `testVersionTypeMismatchIsUnknownVersionReadOnly` | `XCTAssertEqual(store.displayMode, .balanced)` → `.full` |
| `SettingsStoreTests.swift` | 不正な displayMode 値のフォールバックを検証するテスト（`updateDisplayMode(.balanced)` 直後に保存値を見ている箇所） | `XCTAssertEqual(saved["displayMode"] as? String, "balanced")` → `"onePerProvider"` |
| `SettingsStoreTests.swift` | `testMissingVersionActsAsVersionOneAndCanSave` | `XCTAssertEqual(store.displayMode, .compact)` → `.balanced` |
| `SettingsMigrationTests.swift` | version 1 かつ displayMode `"compact"` の JSON を `SettingsStore` で読むテスト | `XCTAssertEqual(loaded.displayMode, .compact)` → `.balanced` |

この5件は静的に特定したもので網羅を保証しない。Step 7 の実行結果で落ちた箇所を同じ方針で更新する。ただし次に当たるテストが落ちた場合は、更新せず停止して依頼元へ報告する。

- displayMode の値そのものが検証対象になっているテスト（移行の是非を問うテスト）
- 期待値を更新するとテストの意図（read-only・バイト保持・フォールバック等）が変わってしまうテスト

`DisplayMode.compact.rawValue` のようにシンボル経由で書かれた箇所は rawValue 変更に自動追随するため通るはずである。通らない場合は想定と実態が食い違っているので停止して報告する。

- [ ] **Step 7: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS（Step 6.5 の期待値更新を含めて達成する条件とする）。既存の `testUpdateSavesAtomicallyAndReloadRoundTrips`（`SettingsStoreTests.swift:22`）は `.balanced` をシンボルで扱うため、rawValue 変更後もそのまま通る。

なお未編集時点のベースラインは `swift build` exit 0 / `swift test` 486 tests・0 failures（2026-08-02 実測）。ここから増えた失敗のみが今回の変更由来である。

- [ ] **Step 8: コミット**

```bash
git add Sources/TakometaCore/Label/MenuBarLabelFormatter.swift \
        Sources/TakometaCore/Settings/SettingsStore.swift \
        Sources/TakometaCore/Notification/NotificationSettingsLoader.swift \
        Tests/TakometaCoreTests/SettingsMigrationTests.swift \
        Tests/TakometaCoreTests/SettingsStoreTests.swift
git commit -m "feat: DisplayMode の永続化写像を新旧区別できるようにする

意味が変わった balanced / compact に新しい rawValue を与え、旧版の値を
1段繰り上げて解釈する fromPersistedValue を追加した。JSON 経路と
UserDefaults 経路の両方を同じ写像へ集約している。

Refs #4"
```

---

### Task 2: select の分岐を再配置する

`Balanced` を「プロバイダごとに最逼迫1枠」へ、`Full` を「モデル枠最大2個」固定へ変える。旧 `Balanced`（モデル枠1個）の挙動は廃止する。

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift:375-426`（`select(windows:mode:)`）
- Test: `Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift:295-340`
- Test: `Tests/TakometaCoreTests/MenuBarColumnsFormatterTests.swift`

**Interfaces:**
- Consumes: Task 1 の `DisplayMode`（3ケース）
- Produces: `select(windows:mode:)` の挙動。`.balanced` は1枠＋種別接頭辞、`.full` は basics + モデル枠2個 + overflow を返す

- [ ] **Step 1: 既存テストのモードを付け替える**

`Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift:341` の `testCompactShowsMostConstrainedBasicWithKindPrefix` を次に置き換える。**期待値 `CL W65` は変えない** — 変えずに通ることが「旧 compact 利用者の見た目が変わらない」ことの証明になる。

```swift
func testBalancedShowsMostConstrainedBasicWithKindPrefix() {
    let label = format([
        window(id: "session", scope: .session, used: 34, kind: .session),
        window(id: "weekly", scope: .weeklyAll, used: 65),
    ], provider: .claude, mode: .balanced)
    XCTAssertEqual(label.text, "CL W65")
}
```

同ファイル `:332` の `testBalancedShowsBasicsAndMostConstrainedNonBasic` を次に置き換える。こちらは**期待値が変わる** — 旧 `balanced` の挙動が廃止され、同じ入力が新 `full` として描画されるため。

```swift
func testLegacyBalancedInputRendersAsFullAfterMigration() {
    let label = format([
        window(id: "session", scope: .session, used: 34, kind: .session),
        window(id: "weekly", scope: .weeklyAll, used: 52),
        window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
        window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
        window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
    ], mode: .full)
    XCTAssertEqual(label.text, "CX 34|52|G78|F65 +1")
}
```

- [ ] **Step 2: 2行表示側のテストを追加する**

`Tests/TakometaCoreTests/MenuBarColumnsFormatterTests.swift` のクラス内に追加する。既存の `columns` / `window` ヘルパーを使う。

```swift
func testBalancedKeepsSingleWindowColumnPerProvider() {
    let result = columns(
        codex: ([
            window(id: "s", scope: .session, used: 34, kind: .session),
            window(id: "w", scope: .weeklyAll, used: 65),
        ], .fresh),
        filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)),
        mode: .balanced)

    // プロバイダラベル列 + 値列1つ。full なら値列が2つ以上になる
    XCTAssertEqual(result.groups.count, 1)
    XCTAssertEqual(result.groups[0].count, 2)
    XCTAssertEqual(result.groups[0][1].value, "65")
}
```

- [ ] **Step 2.5: 旧 Balanced の仕様に依存する既存テストを更新する**

旧 `.balanced`（モデル枠1個 + basics）の出力に依存している既存テストが4件あり、いずれも新仕様では落ちる。

**1件目は目的を反転させる。** `testBalancedAppliesKindOrder` は「Balanced で枠種別の並び順が波及する」ことを検証しているが、新 Balanced は1枠のみを出すため並び順は出力に影響しない。既存の `testCompactIsUnaffectedByKindOrder`（`:129`）と同型に置き換える。

```swift
    // 新しい Balanced は最逼迫1枠だけを出すため、枠種別の並び順は出力に影響しない。
    // 旧 Balanced（モデル枠1個 + basics）では kindOrder が波及していたが、その仕様は廃止された。
    func testBalancedIsUnaffectedByKindOrder() {
        let permutations: [[WindowKindCategory]] = [
            [.session, .weekly, .model], [.session, .model, .weekly],
            [.weekly, .session, .model], [.weekly, .model, .session],
            [.model, .session, .weekly], [.model, .weekly, .session],
        ]
        let baseline = format(fullSet(), mode: .balanced).text
        for order in permutations {
            XCTAssertEqual(
                format(fullSet(), mode: .balanced, kindOrder: order).text, baseline,
                "order: \(order)")
        }
    }
```

**残り3件は期待値のみ追随させる。** これらはフィルタが全モードより先に効くことが主目的で、期待出力はその副産物である。`.full` と `.compact` の行は変更しない。

| テスト | balanced の期待値 |
|---|---|
| `testCombinedSessionFilterRunsBeforeEveryDisplayMode` | `"CX W52\|G78"` → `"CX G78"` |
| `testCombinedWeeklyFilterRunsBeforeEveryDisplayMode` | `"CX H34\|G78"` → `"CX G78"` |
| `testCombinedModelFilterRunsBeforeEveryDisplayMode` | `"CX 34\|52"` → `"CX W52"` |

いずれも同テスト内の `.compact` 行と同じ値になる。これは意図した結果で、テキスト経路の `.compact` が balanced 相当へフォールバックする契約（Step 4 の `case .compact`）を固定する。重複に見えても削除しないこと。

さらに落ちるテストがあれば次の区別で扱う。

- 期待出力が副産物であるテスト（フィルタ・順序・鮮度など別の性質が主目的） → 期待値を新仕様へ追随させる
- 廃止された仕様そのものを検証しているテスト → 停止して依頼元へ報告する（目的の反転が必要な可能性がある）

- [ ] **Step 3: テストが失敗することを確認する**

```bash
swift test --filter MenuBarLabelFormatterTests
```

期待: `testBalancedShowsMostConstrainedBasicWithKindPrefix` が FAIL（現状の `.balanced` は `CL 34|65` 相当を返す）。

- [ ] **Step 4: select の分岐を書き換える**

`Sources/TakometaCore/Label/MenuBarLabelFormatter.swift` の `switch mode { ... }` を次に置き換える。

```swift
        switch mode {
        case .full:
            let bothBasics = session != nil && weekly != nil
            var selected: [SelectedWindow] = []
            if let session {
                selected.append(SelectedWindow(
                    window: session, fixedPrefix: bothBasics ? "" : "H",
                    abbreviationSource: nil))
            }
            if let weekly {
                selected.append(SelectedWindow(
                    window: weekly, fixedPrefix: bothBasics ? "" : "W",
                    abbreviationSource: nil))
            }
            let limit = 2
            selected.append(contentsOf: nonBasic.prefix(limit).map {
                SelectedWindow(
                    window: $0, fixedPrefix: nil,
                    abbreviationSource: abbreviationSource(for: $0.scope))
            })
            return (selected, max(0, nonBasic.count - limit))

        case .balanced:
            guard let window = windows.sorted(by: rankedBefore).first else { return ([], 0) }
            switch window.scope {
            case .session:
                return ([SelectedWindow(
                    window: window, fixedPrefix: "H", abbreviationSource: nil)], 0)
            case .weeklyAll:
                return ([SelectedWindow(
                    window: window, fixedPrefix: "W", abbreviationSource: nil)], 0)
            case .model, .other:
                return ([SelectedWindow(
                    window: window, fixedPrefix: nil,
                    abbreviationSource: abbreviationSource(for: window.scope))], 0)
            }

        case .compact:
            // アイコン表示は select を通らない（formatCombinedIcons が直接ウィンドウを選ぶ）。
            // テキスト経路が .compact で呼ばれた場合は最も近い balanced として描画し、
            // 表示が空になるのを避ける。
            return select(windows: windows, mode: .balanced)
        }
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 6: コミット**

```bash
git add Sources/TakometaCore/Label/MenuBarLabelFormatter.swift \
        Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift \
        Tests/TakometaCoreTests/MenuBarColumnsFormatterTests.swift
git commit -m "feat: Balanced をプロバイダごと1枠へ、Full をモデル枠2個固定へ再配置

旧 balanced（モデル枠1個）を廃止し、旧 compact のロジックを balanced へ
移した。full の limit 可変分岐が消えて定数になる。

Refs #4"
```

---

### Task 3: GaugeLevel と量子化を追加する

使用率を針の角度5段階へ写像する純粋関数を `TakometaCore` に置く。しきい値は最も回帰しやすい箇所なので、境界値を全てテストで固定する。

**Files:**
- Create: `Sources/TakometaCore/Label/MenuBarIcons.swift`
- Test: `Tests/TakometaCoreTests/MenuBarIconsTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `GaugeLevel`（`.zero` / `.low` / `.mid` / `.high` / `.max`）と `GaugeLevel.forUsedPercent(_ percent: Double) -> GaugeLevel`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/TakometaCoreTests/MenuBarIconsTests.swift` を新規作成する。

```swift
import XCTest
@testable import TakometaCore

final class MenuBarIconsTests: XCTestCase {
    func testGaugeLevelBoundaries() {
        let cases: [(Double, GaugeLevel)] = [
            (0, .zero), (19.9, .zero),
            (20, .low), (39.9, .low),
            (40, .mid), (59.9, .mid),
            (60, .high), (79.9, .high),
            (80, .max), (100, .max), (120, .max),
        ]
        for (percent, expected) in cases {
            XCTAssertEqual(
                GaugeLevel.forUsedPercent(percent), expected,
                "\(percent)% の量子化が想定と異なる")
        }
    }

    func testNegativePercentFallsToZero() {
        XCTAssertEqual(GaugeLevel.forUsedPercent(-5), .zero)
    }

    func testNonFinitePercentFallsToMax() {
        // 異常値は危険側へ倒す。針が振り切れていれば利用者が気づける
        XCTAssertEqual(GaugeLevel.forUsedPercent(.nan), .max)
        XCTAssertEqual(GaugeLevel.forUsedPercent(.infinity), .max)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
swift test --filter MenuBarIconsTests
```

期待: `GaugeLevel` が存在せずコンパイルエラー。

- [ ] **Step 3: GaugeLevel を実装する**

`Sources/TakometaCore/Label/MenuBarIcons.swift` を新規作成する。

```swift
/// 使用率を針の角度5段階へ量子化したもの。
/// SF Symbols 名への写像は表示層が持つ ─ Core は UI 詳細を知らない。
public enum GaugeLevel: Sendable, Equatable, CaseIterable {
    case zero, low, mid, high, max

    /// 使用率を5段階へ量子化する。境界は下限を含む（20% ちょうどは `.low`）。
    ///
    /// NaN・無限大は `default` に落ちて `.max` になる。これは意図した挙動で、
    /// 異常値は危険側へ倒す。針が振り切れていれば利用者が異常に気づける。
    public static func forUsedPercent(_ percent: Double) -> GaugeLevel {
        switch percent {
        case ..<20: return .zero
        case ..<40: return .low
        case ..<60: return .mid
        case ..<80: return .high
        default: return .max
        }
    }
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
swift test --filter MenuBarIconsTests
```

期待: PASS。

- [ ] **Step 5: コミット**

```bash
git add Sources/TakometaCore/Label/MenuBarIcons.swift \
        Tests/TakometaCoreTests/MenuBarIconsTests.swift
git commit -m "feat: 使用率を針の角度5段階へ量子化する GaugeLevel を追加

境界値と異常値（NaN・無限大）の挙動をテストで固定した。異常値は危険側の
.max へ倒す。

Refs #4"
```

---

### Task 4: MenuBarIcons 型と formatCombinedIcons を追加する

プロバイダごとに1つのアイコンを組み立てる。値が取得できないケースを型で分離し、0% 表示を構造的に防ぐ。

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarIcons.swift`（Task 3 で作成）
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift`（`formatCombinedIcons` を追加）
- Test: `Tests/TakometaCoreTests/MenuBarIconsTests.swift`

**Interfaces:**
- Consumes: Task 3 の `GaugeLevel.forUsedPercent(_:)`、既存の `resolveProviders` / `rankedBefore` / `style(for:freshness:now:)` / `resolvedPrefixTitle(provider:custom:)`
- Produces:
  - `MenuBarIconGlyph`（`.gauge(GaugeLevel)` / `.unavailable` / `.authenticationRequired`）
  - `MenuBarIcon`（`glyph` / `style` / `isStale` / `accessibilityText`）
  - `MenuBarIcons`（`icons: [MenuBarIcon]` / `accessibilityText: String`）
  - `MenuBarLabelFormatter.formatCombinedIcons(codex:claude:filter:now:order:labels:) -> MenuBarIcons`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/TakometaCoreTests/MenuBarIconsTests.swift` に追加する。

```swift
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String, scope: RateLimitScope, used: Double,
        kind: WindowKind? = .weekly, resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func icons(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter()
    ) -> MenuBarIcons {
        MenuBarLabelFormatter.formatCombinedIcons(
            codex: codex, claude: claude, filter: filter, now: now)
    }

    func testOneIconPerVisibleProviderUsesMostConstrainedWindow() {
        let result = icons(
            codex: ([
                window(id: "s", scope: .session, used: 34, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 65),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons.count, 1)
        XCTAssertEqual(result.icons[0].glyph, .gauge(.high))
    }

    func testHiddenProviderProducesNoIcon() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 10)], .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(show: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertTrue(result.icons.isEmpty)
    }

    func testUnavailableProducesUnavailableGlyphNotZeroGauge() {
        let result = icons(
            codex: ([], .unavailable),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .unavailable)
    }

    func testEmptyWindowListProducesUnavailableGlyph() {
        let result = icons(
            codex: ([], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .unavailable)
    }

    func testAuthenticationRequiredProducesLockGlyph() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .authenticationRequired)
    }

    func testStaleIsMarkedWithoutChangingGlyph() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .stale),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .gauge(.mid))
        XCTAssertTrue(result.icons[0].isStale)
        XCTAssertTrue(result.icons[0].accessibilityText.contains("更新が古い"))
    }

    func testAccessibilityTextJoinsProvidersWithTwoSpaces() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 49)], .fresh),
            claude: ([window(id: "s", scope: .session, used: 20, kind: .session)], .fresh))

        XCTAssertEqual(result.accessibilityText, "CX 週間枠 49%  CL 5時間枠 20%")
    }
}
```

既存の閉じ括弧と重複しないよう、Task 3 で書いたクラスの末尾に差し込むこと。

- [ ] **Step 2: テストが失敗することを確認する**

```bash
swift test --filter MenuBarIconsTests
```

期待: `MenuBarIcon` / `formatCombinedIcons` が存在せずコンパイルエラー。

- [ ] **Step 3: 型を追加する**

`Sources/TakometaCore/Label/MenuBarIcons.swift` の `GaugeLevel` の下に追記する。

```swift
/// アイコンが何を描くか。値がないケースを `GaugeLevel` から分離することで、
/// 「値が取得できないときに 0% を表示しない」原則を型で守る。
public enum MenuBarIconGlyph: Sendable, Equatable {
    case gauge(GaugeLevel)
    case unavailable
    case authenticationRequired
}

public struct MenuBarIcon: Sendable, Equatable {
    public let glyph: MenuBarIconGlyph
    public let style: SegmentStyle
    public let isStale: Bool
    public let accessibilityText: String

    public init(
        glyph: MenuBarIconGlyph,
        style: SegmentStyle,
        isStale: Bool,
        accessibilityText: String
    ) {
        self.glyph = glyph
        self.style = style
        self.isStale = isStale
        self.accessibilityText = accessibilityText
    }
}

public struct MenuBarIcons: Sendable, Equatable {
    public let icons: [MenuBarIcon]

    public init(icons: [MenuBarIcon]) {
        self.icons = icons
    }

    /// VoiceOver 用。プロバイダの区切りは半角スペース2つ。
    /// 区切り幅は `MenuBarColumns.accessibilityText` のグループ区切りに揃える。
    public var accessibilityText: String {
        icons.map(\.accessibilityText).joined(separator: "  ")
    }
}
```

- [ ] **Step 4: formatCombinedIcons を実装する**

`Sources/TakometaCore/Label/MenuBarLabelFormatter.swift` の `formatCombinedColumns` の直後に追記する。

```swift
    public static func formatCombinedIcons(
        codex: (windows: [RateLimitWindow], freshness: Freshness)?,
        claude: (windows: [RateLimitWindow], freshness: Freshness)?,
        filter: DisplayFilter,
        now: Date,
        order: [ProviderID] = [.codex, .claude],
        labels: [ProviderID: String] = [:]
    ) -> MenuBarIcons {
        // アイコンは1プロバイダ1個のため枠種別の並び順は影響しない。kindOrders は空で渡す。
        let resolved = resolveProviders(
            codex: codex, claude: claude, filter: filter,
            order: order, labels: labels, kindOrders: [:])
        return MenuBarIcons(icons: resolved.map { icon(for: $0, now: now) })
    }

    private static func icon(for item: ResolvedProvider, now: Date) -> MenuBarIcon {
        let prefix = resolvedPrefixTitle(provider: item.provider, custom: item.label)

        if item.freshness == .authenticationRequired {
            return MenuBarIcon(
                glyph: .authenticationRequired, style: .normal, isStale: false,
                accessibilityText: "\(prefix) 要認証")
        }

        guard item.freshness != .unavailable,
              let window = item.windows.sorted(by: rankedBefore).first
        else {
            return MenuBarIcon(
                glyph: .unavailable, style: .normal, isStale: false,
                accessibilityText: "\(prefix) 取得できません")
        }

        let isStale = item.freshness == .stale
        let percent = Int(window.usedPercent.rounded(.down))
        return MenuBarIcon(
            glyph: .gauge(GaugeLevel.forUsedPercent(window.usedPercent)),
            style: style(for: window, freshness: item.freshness, now: now),
            isStale: isStale,
            accessibilityText: "\(prefix) \(scopeName(for: window.scope)) \(percent)%"
                + (isStale ? "（更新が古い）" : ""))
    }

    /// アクセシビリティ用の枠名。表記は既存 UI（`SettingsView.windowKindOrderLabel`）に揃える。
    private static func scopeName(for scope: RateLimitScope) -> String {
        switch scope {
        case .session: return "5時間枠"
        case .weeklyAll: return "週間枠"
        case .model(_, let displayName): return displayName
        case .other(let raw): return raw
        }
    }
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
swift test --filter MenuBarIconsTests
```

期待: PASS。`testAccessibilityTextJoinsProvidersWithTwoSpaces` が落ちる場合は、`resolvedPrefixTitle` が返す既定ラベル（`CX` / `CL`）を実際の出力で確認して期待値を合わせる。

- [ ] **Step 6: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 7: コミット**

```bash
git add Sources/TakometaCore/Label/MenuBarIcons.swift \
        Sources/TakometaCore/Label/MenuBarLabelFormatter.swift \
        Tests/TakometaCoreTests/MenuBarIconsTests.swift
git commit -m "feat: アイコン表示用の MenuBarIcons と formatCombinedIcons を追加

値が取得できないケースを MenuBarIconGlyph の別ケースとして分離し、0% 表示を
型で防いでいる。色は既存の style(for:) を再利用し、針＝使用率／色＝ペースの
二重符号化とした。

Refs #4"
```

---

### Task 5: アイコンを描画し、表示経路を3分岐にする

**Files:**
- Modify: `Sources/TakometaApp/MenuBarLabelView.swift:26-47`（`body`）
- Modify: `Sources/TakometaApp/MenuBarLabelView.swift`（`MenuBarIconsView` を追加）

**Interfaces:**
- Consumes: Task 4 の `MenuBarIcons` / `MenuBarIcon` / `MenuBarIconGlyph` / `GaugeLevel`、`MenuBarLabelFormatter.formatCombinedIcons`
- Produces: なし（表示層の末端）

- [ ] **Step 1: MenuBarIconsView を追加する**

`Sources/TakometaApp/MenuBarLabelView.swift` の `MenuBarSegmentView` の下に追記する。SF Symbols 名がコードに現れるのはこの層だけ。

```swift
private struct MenuBarIconsView: View {
    let icons: MenuBarIcons

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(icons.icons.enumerated()), id: \.offset) { _, icon in
                Image(systemName: symbolName(for: icon.glyph))
                    .foregroundStyle(color(for: icon))
                    // stale はマークを足さず不透明度で示す。Compact の存在理由が
                    // 幅なので、ここで幅を増やすと目的と矛盾する
                    .opacity(icon.isStale ? 0.45 : 1)
            }
        }
        .font(.system(size: 13))
        .fixedSize()
    }

    private func symbolName(for glyph: MenuBarIconGlyph) -> String {
        switch glyph {
        case .gauge(let level):
            switch level {
            case .zero: return "gauge.with.dots.needle.0percent"
            case .low: return "gauge.with.dots.needle.33percent"
            case .mid: return "gauge.with.dots.needle.50percent"
            case .high: return "gauge.with.dots.needle.67percent"
            case .max: return "gauge.with.dots.needle.100percent"
            }
        case .unavailable: return "questionmark.circle"
        case .authenticationRequired: return "lock.circle"
        }
    }

    private func color(for icon: MenuBarIcon) -> Color {
        switch icon.glyph {
        case .unavailable, .authenticationRequired:
            return .secondary
        case .gauge:
            switch icon.style {
            case .normal: return .primary
            case .warning: return Color(nsColor: .systemOrange)
            case .critical: return Color(nsColor: .systemRed)
            }
        }
    }
}
```

- [ ] **Step 2: formattedIcons を追加する**

`MenuBarLabelView` の `formattedColumns`（`:62-73`）の下に追記する。

```swift
    private var formattedIcons: MenuBarIcons {
        _ = store.revision
        return MenuBarLabelFormatter.formatCombinedIcons(
            codex: input(for: .codex),
            claude: input(for: .claude),
            filter: SettingsSupply.displayFilter(from: settingsStore.providers),
            now: Date(),
            order: settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:)),
            labels: SettingsSupply.providerLabels(from: settingsStore.providers))
    }
```

- [ ] **Step 3: body を3分岐にする**

`MenuBarLabelView.body`（`:26-47`）を次に置き換える。

```swift
    @ViewBuilder
    var body: some View {
        if settingsStore.displayMode == .compact {
            let icons = formattedIcons
            if icons.icons.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarIconsView(icons: icons)))
                    .renderingMode(.original)
                    .accessibilityLabel(icons.accessibilityText)
            }
        } else if settingsStore.menuBarLineCount == .two {
            let columns = formattedColumns
            if columns.groups.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarColumnsView(columns: columns)))
                    .renderingMode(.original)
                    .accessibilityLabel(columns.accessibilityText)
            }
        } else {
            let label = formattedLabel
            if label.segments.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarSegmentView(label: label)))
                    .renderingMode(.original)
                    .accessibilityLabel(label.text)
            }
        }
    }
```

- [ ] **Step 4: プレビューを追加する**

ファイル末尾の既存 `#Preview` の下に追記する。実機確認の前に見た目を確かめられるようにする。

```swift
#Preview("アイコン表示 - 5段階") {
    MenuBarIconsView(icons: MenuBarIcons(icons: [
        MenuBarIcon(glyph: .gauge(.zero), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 10%"),
        MenuBarIcon(glyph: .gauge(.low), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 30%"),
        MenuBarIcon(glyph: .gauge(.mid), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 50%"),
        MenuBarIcon(glyph: .gauge(.high), style: .warning, isStale: false,
                    accessibilityText: "CX 週間枠 70%"),
        MenuBarIcon(glyph: .gauge(.max), style: .critical, isStale: false,
                    accessibilityText: "CX 週間枠 95%"),
    ]))
    .padding(8)
    .background(.bar)
}

#Preview("アイコン表示 - 退化ケース") {
    MenuBarIconsView(icons: MenuBarIcons(icons: [
        MenuBarIcon(glyph: .gauge(.mid), style: .normal, isStale: true,
                    accessibilityText: "CX 週間枠 50%（更新が古い）"),
        MenuBarIcon(glyph: .unavailable, style: .normal, isStale: false,
                    accessibilityText: "CX 取得できません"),
        MenuBarIcon(glyph: .authenticationRequired, style: .normal, isStale: false,
                    accessibilityText: "CL 要認証"),
    ]))
    .padding(8)
    .background(.bar)
}
```

- [ ] **Step 5: ビルドを通す**

```bash
swift build
```

期待: エラーなし。

- [ ] **Step 6: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 7: コミット**

```bash
git add Sources/TakometaApp/MenuBarLabelView.swift
git commit -m "feat: Compact モードでゲージアイコンを描画する

表示経路を displayMode / lineCount の3分岐にした。SF Symbols 名は表示層に
閉じ込め、Core は GaugeLevel の抽象段階のみを扱う。

Refs #4"
```

---

### Task 6: Compact 選択時に行数設定を無効化する

`displayMode` × `menuBarLineCount` の直積のうち「Compact × 2行」だけが意味を持たない。選べるのに何も起きない状態を残さない。

**Files:**
- Modify: `Sources/TakometaApp/SettingsView.swift:89-92`

**Interfaces:**
- Consumes: Task 1 の `DisplayMode.compact`
- Produces: なし

- [ ] **Step 1: Picker を無効化し理由を添える**

`Sources/TakometaApp/SettingsView.swift:89-92` を次に置き換える。

```swift
                Picker("メニューバーの行数", selection: menuBarLineCountBinding) {
                    Text("1行").tag(MenuBarLineCount.one)
                    Text("2行").tag(MenuBarLineCount.two)
                }
                .disabled(settingsStore.displayMode == .compact)

                if settingsStore.displayMode == .compact {
                    Text("Compact はアイコンのみのため行数は適用されません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

設定値は書き換えない。`.disabled` は表示の抑止だけで、Balanced / Full へ戻せば元の行数が復活する。

- [ ] **Step 2: ビルドを通す**

```bash
swift build
```

期待: エラーなし。

- [ ] **Step 3: コミット**

```bash
git add Sources/TakometaApp/SettingsView.swift
git commit -m "feat: Compact 選択時は行数設定を無効化する

アイコン表示に行数の概念がないため。設定値は保持し、Balanced / Full へ
戻した時点で元の行数が復活する。

Refs #4"
```

---

### Task 7: 実機確認と CHANGELOG 更新

自動テストでは判定できない項目を実機で確認する。設計書 §9 のリスク1・2はここで判定する。

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1〜6 のすべて
- Produces: なし

- [ ] **Step 1: アプリをビルドして起動する**

```bash
scripts/make-app.sh
```

```bash
open dist/Takometa.app
```

- [ ] **Step 2: 移行が効いていることを確認する**

起動前の設定は `displayMode = balanced`（旧版の値）。起動後に次を確認する。

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Takometa/provider-settings.json'
d = json.load(p.open())
print('displayMode =', d.get('displayMode'))
"
```

期待: 設定を1度でも変更した後は `full` になっている。メニューバーの表示内容は移行前と変わっていない（モデル固有枠が1個以下のため）。

- [ ] **Step 3: 3モードを切り替えて幅と判別性を確認する**

設定画面から Full → Balanced → Compact と切り替え、次を確認する。

- Compact で針の角度が段階ごとに判別できるか（**設計書 §9 リスク1**）。判別できない場合は Task 3 の `forUsedPercent` を3段階（`.zero` / `.mid` / `.max`）へ縮退させ、Task 5 の `symbolName` を `0/50/100percent` の3つに減らす
- Compact 選択時に行数 Picker がグレーアウトし、説明文が出るか
- Balanced に戻したとき行数設定（2行）が復活するか
- 内蔵ディスプレイのみの状態で Compact なら押し出されずに表示されるか（**本 Issue の目的**）

- [ ] **Step 4: stale の見え方を確認する**

ネットワークを切るなどして stale 状態を作り、不透明度を落としたアイコンが warning の橙と紛らわしくないか確認する（**設計書 §9 リスク2**）。紛らわしい場合は Task 5 の `.opacity(0.45)` を調整する。

- [ ] **Step 5: CHANGELOG を更新する**

`CHANGELOG.md` の `[Unreleased]` に追記する。

```markdown
### Changed

- メニューバー表示モードを「占有幅の段階」として再定義した。`Balanced` はプロバイダごとに最も逼迫した1枠のみを表示するようになり、`Full` は従来どおり全枠を表示する。既存の設定は自動で移行され、表示内容は変わらない
- `Compact` をゲージアイコンのみの表示に変更した。針の角度が使用率を、色が消費ペースを示す。メニューバーの幅が不足する環境向け
- `Compact` 選択時は行数設定を無効化した（アイコン表示に行数の概念がないため）
```

- [ ] **Step 6: コミットしてプッシュする**

```bash
git add CHANGELOG.md
git commit -m "docs: メニューバー表示モードの変更を CHANGELOG へ追記

Refs #4"
```

```bash
git push -u origin feat/4-menubar-display-modes
```

- [ ] **Step 7: PR を作成する**

```bash
gh pr create --title "メニューバー表示モードを「占有幅の段階」として再設計する" --body "$(cat <<'BODY'
Closes #4

## 変更内容

3つの表示モードの軸を「占有幅の段階」に統一した。

| モード | 中身 |
|---|---|
| Full | session + weekly + モデル枠最大2 + `+N`（現行維持） |
| Balanced | プロバイダごとに最逼迫1枠（現 compact のロジックを移設） |
| Compact | ゲージアイコンのみ（新規。針＝使用率／色＝ペース） |

設計書: `.docs/plans/4-menubar-display-modes-design.md`

## 移行

既存の設定値は1段繰り上げて解釈する。旧版と新版で意味が変わった case には
新しい rawValue を与えており、写像は冪等。

## 検証

- `swift build` / `swift test` 完走
- 実機で3モードの切り替え・移行・退化ケースを確認

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## レビューサイクル

コード変更を含むため、プロジェクト CLAUDE.md のレビューサイクル表に従い、`swift build` / `swift test` 通過後に次のレビュアーを起動する。flag された確信度80%以上の指摘が0になるまで「修正 → 再レビュー」を反復する。

| 条件 | レビュアー |
|---|---|
| コード変更（常時） | `pr-review-toolkit:code-reviewer` |
| 新しい型 / インターフェースを追加（Task 3・4） | `pr-review-toolkit:type-design-analyzer` |
| テストを追加 / 変更（Task 1〜4） | `pr-review-toolkit:pr-test-analyzer` |
| コメントを追加 / 変更（全タスク） | `pr-review-toolkit:comment-analyzer` |

`silent-failure-hunter` は try-catch / フォールバックを新規に書かないため対象外。ただし Task 2 の `.compact` フォールバック（`select` が balanced 相当を返す）は fallback に該当するため、`code-reviewer` の指摘対象として意識する。
