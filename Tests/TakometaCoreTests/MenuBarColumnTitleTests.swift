import XCTest
@testable import TakometaCore

final class MenuBarColumnTitleTests: XCTestCase {
    private func titles(_ scopes: [RateLimitScope]) -> [String] {
        MenuBarLabelFormatter.columnTitles(for: scopes)
    }

    private func model(_ name: String, id: String? = nil) -> RateLimitScope {
        .model(id: id, displayName: name)
    }

    func testSessionAndWeeklyUseFixedNames() {
        XCTAssertEqual(titles([.session, .weeklyAll]), ["5h", "1w"])
    }

    func testShortModelNameIsNotTruncated() {
        XCTAssertEqual(titles([model("Fable")]), ["Fable"])
    }

    func testEightCharacterNameIsNotTruncated() {
        XCTAssertEqual(titles([model("Sonnet45")]), ["Sonnet45"])
    }

    func testLongNameIsTruncatedToEightCharacters() {
        // 先頭7文字 + … で全体8文字
        let result = titles([model("GPT-5.3-Codex-Spark")])
        XCTAssertEqual(result, ["GPT-5.3…"])
        XCTAssertEqual(result[0].count, 8)
    }

    func testOtherScopeUsesRawValue() {
        XCTAssertEqual(titles([.other("raw_x")]), ["raw_x"])
    }

    func testEmptyDisplayNameFallsBackToQuestionMark() {
        // CodexRateLimitsDecoder は limitName ?? limitId をそのまま渡すため空文字がありうる
        XCTAssertEqual(titles([model("")]), ["?"])
        XCTAssertEqual(titles([.other("")]), ["?"])
    }

    func testCollisionOfTruncatedNamesSwitchesToMiddleEllipsis() {
        // どちらも9文字以上で先頭8文字が同じ → 中央省略（先頭3 + … + 末尾4）
        let result = titles([model("GPT-5.3-Codex-Spark"), model("GPT-5.3-Codex-Max")])
        XCTAssertEqual(result, ["GPT…park", "GPT…-Max"])
        XCTAssertNotEqual(result[0], result[1])
        XCTAssertEqual(result[0].count, 8)
        XCTAssertEqual(result[1].count, 8)
    }

    func testShortDuplicateNamesDoNotUseMiddleEllipsis() {
        // 8文字以下の同名は切り詰めが発生していないので中央省略しない（N-5）。
        // 無条件に中央省略する実装だと "Fab…able" のような元文字列に無い綴りが出る
        XCTAssertEqual(titles([model("Fable", id: "a"), model("Fable", id: "b")]), ["Fable", "Fable"])
    }

    func testMiddleEllipsisCollisionFallsBackToPrefixTruncation() {
        // 先頭8文字が同一（＝先頭切り詰めで衝突）かつ、先頭3+末尾4も同一（＝中央省略でも衝突）。
        // このとき中央省略 "ABC…WXYZ" ではなく先頭切り詰めの結果へ戻る。
        // 入力が先頭切り詰めの時点で衝突しないと、この経路に入らず空回りするテストになる
        let result = titles([model("ABCDEFGHxxxWXYZ"), model("ABCDEFGHyyyWXYZ")])
        XCTAssertEqual(result, ["ABCDEFG…", "ABCDEFG…"])
    }

    func testCollisionCheckIsScopedToGivenArray() {
        // 単独なら衝突しないので先頭切り詰めのまま
        XCTAssertEqual(titles([model("GPT-5.3-Codex-Spark")]), ["GPT-5.3…"])
    }
}
