import XCTest
@testable import SimToolServer

final class LocalizationIndexTests: XCTestCase {
    // The classic `.strings` table is an old-style plist; the reverse lookup
    // returns every key that mints a visible string, in on-screen order.
    func testStringsTableReverseLookup() {
        let table = Data("""
        /* Lokalise snapshot */
        "payment_links_title" = "Payment links";
        "campaign_widget_payment_links_title" = "Payment links";
        "verify_identity_button" = "Verify my identity";
        """.utf8)
        let entries = LocalizationIndex.parseStringsTable(table)
        var keysByValue: [String: [String]] = [:]
        for (key, value) in entries { keysByValue[value, default: []].append(key) }
        let index = LocalizationIndex(keysByValue: keysByValue)

        let keys = index.keys(forLabels: ["Verify my identity", "Payment links", "$10,000"])
        XCTAssertEqual(keys, [
            "verify_identity_button",
            "campaign_widget_payment_links_title",
            "payment_links_title",
        ])
    }

    // `.xcstrings` catalogs: every localization's value counts, and an entry
    // with no localizations displays its own key.
    func testCatalogParsing() {
        let catalog = Data("""
        {
          "sourceLanguage": "en",
          "strings": {
            "greeting.title": {
              "localizations": {
                "en": { "stringUnit": { "state": "translated", "value": "Hello" } },
                "es": { "stringUnit": { "state": "translated", "value": "Hola" } }
              }
            },
            "Plain source text": {}
          }
        }
        """.utf8)
        let entries = LocalizationIndex.parseCatalog(catalog)
        XCTAssertTrue(entries.contains { $0.key == "greeting.title" && $0.value == "Hello" })
        XCTAssertTrue(entries.contains { $0.key == "greeting.title" && $0.value == "Hola" })
        XCTAssertTrue(entries.contains { $0.key == "Plain source text" && $0.value == "Plain source text" })
    }

    // One-character labels ("+", "1") would match half the table by accident.
    func testTooShortLabelsDoNotMatch() {
        let index = LocalizationIndex(keysByValue: ["1": ["digit_one"]])
        XCTAssertEqual(index.keys(forLabels: ["1"]), [])
    }

    // "Back" is minted by dozens of keys: the match identifies none of them
    // and only buries the screen's own keys in noise.
    func testOverlyAmbiguousValuesAreSkipped() {
        let index = LocalizationIndex(keysByValue: [
            "Back": ["k1", "k2", "k3", "k4", "k5"],
            "Invite a friend": ["baf_main_title"],
        ])
        XCTAssertEqual(index.keys(forLabels: ["Back", "Invite a friend"]), ["baf_main_title"])
    }
}
