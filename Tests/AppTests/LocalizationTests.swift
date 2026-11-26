import AlbumWinnowApple
import XCTest
@testable import AlbumWinnowAcceptance

final class LocalizationTests: XCTestCase {
    func testEveryApplicableMessageAndPermissionPurposeIsPackagedInAllThreeLanguages() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "messages", withExtension: "json"))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let messages = try XCTUnwrap(data["messages"] as? [[String: Any]])
        let sampleName = "100% 東京 \"A\" {literal}\n写真.png"
        for language in ["en", "zh-Hans", "ja"] {
            let resource = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: resource))
            for message in messages where (message["platforms"] as? [String])?.contains("apple") == true {
                let id = try XCTUnwrap(message["id"] as? String)
                let table = message["table"] as? String ?? "Localizable"
                let key = message["appleKey"] as? String ?? id
                let translations = try XCTUnwrap(message["translations"] as? [String: Any])
                if table == "InfoPlist" {
                    XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: table), translations[language] as? String)
                } else {
                    let parameters = message["parameters"] as? [[String: String]] ?? []
                    let arguments: [CVarArg] = parameters.map { $0["type"] == "integer" ? Int64(2) as CVarArg : sampleName as CVarArg }
                    let value = L10n.format(id, arguments: arguments, bundle: bundle, locale: Locale(identifier: language))
                    XCTAssertNotEqual(value, id, "Missing \(language) resource: \(id)")
                    XCTAssertFalse(value.isEmpty)
                    XCTAssertFalse(value.contains("%1$"), id)
                    XCTAssertFalse(value.contains("%#@"), id)
                    if parameters.contains(where: { $0["type"] == "text" }) {
                        XCTAssertTrue(value.contains(sampleName), "User text was reformatted: \(language) \(id)")
                    }
                }
            }
        }
    }

    func testNativePluralSelectionArgumentReorderingAndEnglishFallback() throws {
        for (language, singular, plural) in [("en", "1 photo", "2 photos"), ("zh-Hans", "1 张照片", "2 张照片"), ("ja", "1枚の写真", "2枚の写真")] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            let locale = Locale(identifier: language)
            XCTAssertEqual(L10n.format("photo_count", arguments: [Int64(1)], bundle: bundle, locale: locale), singular)
            XCTAssertEqual(L10n.format("photo_count", arguments: [Int64(2)], bundle: bundle, locale: locale), plural)
            XCTAssertTrue(L10n.format("photo_count", arguments: [Int64(0)], bundle: bundle, locale: locale).contains("0"))
            XCTAssertTrue(L10n.format("photo_count", arguments: [Int64(10000)], bundle: bundle, locale: locale).contains("10,000"))
            let partial = L10n.format("app_at_least_arg1_plus_arg2_photos_of_unknown_size", arguments: [Int64(1), "12 MB"], bundle: bundle, locale: locale)
            XCTAssertTrue(partial.contains("12 MB"))
            XCTAssertTrue(partial.contains("1"))
            if language == "en" { XCTAssertEqual(partial, "At least 12 MB, plus 1 photo of unknown size") }
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "zh-Hans", "ja"], forPreferences: ["fr"]), ["en"])
    }

    func testKnownFailuresUseStructuredReasonsAndUnknownDiagnosticsRemainLiteral() {
        XCTAssertEqual(L10n.cleanupReason(.inaccessible), "This photo is no longer accessible from its source.")
        XCTAssertEqual(L10n.cleanupReason(.readOnlySource), L10n.error(CleanupError.readOnlySource))
        XCTAssertEqual(L10n.cleanupReason(.userProtected), L10n.error(CleanupError.userProtected))
        XCTAssertEqual(L10n.error(CleanupError.protectedResources), CleanupError.protectedResources.localizedDescription)
        let detail = "100% \"camera\" {literal}\n原始情報"
        XCTAssertTrue(L10n.error(NSError(domain: "Fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: detail])).contains(detail))
    }
}
