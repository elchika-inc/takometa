import XCTest
@testable import TakometaFixtureSupport

final class FixtureSanitizerTests: XCTestCase {
    func testAllowedKeysKeepUsageValues() throws {
        let data = #"{"five_hour":{"utilization":8.0,"resets_at":"2026-07-19T13:30:00Z"}}"#
            .data(using: .utf8)!
        let output = try FixtureSanitizer.sanitizedData(from: data)
        let root = try JSONSerialization.jsonObject(with: output) as! [String: Any]
        let fiveHour = root["five_hour"] as! [String: Any]

        XCTAssertEqual(fiveHour["utilization"] as? Double, 8.0)
        XCTAssertEqual(fiveHour["resets_at"] as? String, "2026-07-19T13:30:00Z")
    }

    func testUnknownTopLevelKeyIsRedactedAndNameIsReported() throws {
        var logs: [String] = []
        let output = FixtureSanitizer.sanitize(
            jsonObject: ["credential": "sensitive-test-value", "rateLimits": [:]],
            onLog: { logs.append($0) }) as! [String: Any]

        XCTAssertEqual(output["credential"] as? String, "<redacted>")
        XCTAssertTrue(logs.contains { $0.contains("credential") })
    }

    func testAllowlistedSubstringDoesNotPermitUnknownKey() {
        var logs: [String] = []
        let output = FixtureSanitizer.sanitize(
            jsonObject: ["user_id": "sensitive-test-value", "uuid": "sensitive-test-value"],
            onLog: { logs.append($0) }) as! [String: Any]

        XCTAssertEqual(output["user_id"] as? String, "<redacted>")
        XCTAssertEqual(output["uuid"] as? String, "<redacted>")
        XCTAssertTrue(logs.contains { $0.contains("user_id") })
        XCTAssertTrue(logs.contains { $0.contains("uuid") })
    }

    func testDynamicMapUnknownChildKeyIsAnonymousInOutputAndLogs() throws {
        let rawKey = "private-bucket-test-value"
        var logs: [String] = []
        let output = FixtureSanitizer.sanitize(
            jsonObject: [
                "rateLimitsByLimitId": [
                    rawKey: [
                        "limitId": rawKey,
                        "limitName": "Private Model Test Value",
                        "primary": ["usedPercent": 42],
                    ],
                ],
            ],
            onLog: { logs.append($0) })
        let text = try serializedText(output)

        XCTAssertFalse(text.contains(rawKey))
        XCTAssertFalse(logs.joined(separator: " ").contains(rawKey))
        XCTAssertTrue(text.contains("<redacted-key-1>"))
        XCTAssertTrue(logs.contains { $0.contains("1件") })
    }

    func testAnonymousMapKeyReplacesMatchingLimitIDEverywhere() throws {
        let rawKey = "private-bucket-test-value"
        let output = FixtureSanitizer.sanitize(jsonObject: [
            "rateLimitsByLimitId": [
                rawKey: ["limitId": rawKey, "limitName": "Private Model Test Value"],
            ],
            "rateLimits": ["limitId": rawKey, "limitName": "Private Model Test Value"],
        ])
        let text = try serializedText(output)

        XCTAssertFalse(text.contains(rawKey))
        XCTAssertGreaterThanOrEqual(
            text.components(separatedBy: "<redacted-key-1>").count - 1,
            3)
    }

    func testAnonymousScopeReplacesDifferentLimitNameAndDuplicate() throws {
        let rawKey = "private-bucket-test-value"
        let rawName = "Private Model Test Value"
        let output = FixtureSanitizer.sanitize(jsonObject: [
            "rateLimitsByLimitId": [
                rawKey: ["limitId": rawKey, "limitName": rawName],
            ],
            "rateLimits": ["limitId": rawKey, "limitName": rawName],
        ])
        let text = try serializedText(output)

        XCTAssertFalse(text.contains(rawName))
        XCTAssertTrue(text.contains("<redacted-value-1>"))
    }

    func testIdentifierNameIsRedactedWithoutByIDMap() throws {
        let rawName = "Unseen Model Test Value"
        let output = FixtureSanitizer.sanitize(jsonObject: [
            "rateLimits": [
                "limitId": "codex",
                "limitName": rawName,
                "primary": ["usedPercent": 42],
            ],
        ])

        XCTAssertFalse(try serializedText(output).contains(rawName))
    }

    func testClaudeModelIdentityAndNameAreRedacted() throws {
        let rawID = "unseen-model-test-value"
        let rawName = "Unseen Model Test Value"
        let output = FixtureSanitizer.sanitize(jsonObject: [
            "limits": [[
                "scope": [
                    "model": ["id": rawID, "display_name": rawName],
                ],
                "percent": 42,
            ]],
        ])
        let text = try serializedText(output)

        XCTAssertFalse(text.contains(rawID))
        XCTAssertFalse(text.contains(rawName))
    }

    func testUnknownNestedKeyOutsideFixedSchemaIsAnonymousAndNotReportedByName() throws {
        let rawKey = "private-child-test-value"
        var logs: [String] = []
        let output = FixtureSanitizer.sanitize(
            jsonObject: [
                "disclaimer": [rawKey: "sensitive-test-value"],
            ],
            onLog: { logs.append($0) })
        let text = try serializedText(output)

        XCTAssertFalse(text.contains(rawKey))
        XCTAssertFalse(logs.joined(separator: " ").contains(rawKey))
        XCTAssertTrue(text.contains("<redacted-key-1>"))
    }

    func testExistingFixturesAreIdempotent() throws {
        let fixtures = [
            ("codex", "live_masked"),
            ("codex", "missing_values"),
            ("codex", "multi_bucket"),
            ("codex", "single_bucket_with_secondary"),
            ("claude", "legacy_model_fields"),
            ("claude", "live_masked"),
            ("claude", "missing_values"),
            ("claude", "normal"),
            ("claude", "unknown_fields"),
        ]

        for (provider, name) in fixtures {
            let url = try XCTUnwrap(Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/\(provider)"))
            let input = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let output = FixtureSanitizer.sanitize(jsonObject: input)
            XCTAssertEqual(
                try normalizedData(input),
                try normalizedData(output),
                "\(provider)/\(name).json")
        }
    }

    private func serializedText(_ object: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]),
            as: UTF8.self)
    }

    private func normalizedData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
