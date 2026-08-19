import XCTest
@testable import SimToolServer

final class DeeplinkHarvestTests: XCTestCase {
    // The schemes come from the installed bundle's Info.plist — the scan
    // never guesses which URLs belong to the app.
    func testSchemesComeFromBundleURLTypes() {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleURLTypes</key>
          <array>
            <dict>
              <key>CFBundleURLSchemes</key>
              <array><string>plata</string></array>
            </dict>
            <dict>
              <key>CFBundleURLSchemes</key>
              <array><string>plata-dev</string><string>plata</string></array>
            </dict>
          </array>
        </dict></plist>
        """.utf8)
        XCTAssertEqual(DeeplinkHarvest.schemes(fromInfoPlist: plist), ["plata", "plata-dev"])
        XCTAssertEqual(DeeplinkHarvest.schemes(fromInfoPlist: Data("junk".utf8)), [])
    }

    // Literals are mined and cleaned: an interpolation cuts the URL down to
    // its static base route, `...` placeholders and trailing punctuation are
    // trimmed, destructive/service routes are dropped.
    func testUrlLiteralsAreMinedAndCleaned() {
        let source = """
        router.open("plata://home/card")
        let provider = "plata://payments/bill_payments/provider"
        let dynamic = "plata://transaction/\\(id)"
        let dots = "plata://invest/..."
        let service = "plata://api-recorder/clear"
        let bare = "plata://"
        """
        let urls = DeeplinkHarvest.urls(inText: source, schemes: ["plata"])
        XCTAssertEqual(Set(urls), [
            "plata://home/card",
            "plata://payments/bill_payments/provider",
            "plata://transaction",
            "plata://invest",
        ])
    }

    // Top-level routes go first: they are the likeliest to name a screen
    // outright, and the harvest is capped.
    func testHarvestOrderPrefersShallowRoutes() {
        let urls = ["plata://a/b/c", "plata://home", "plata://a/b"]
        let sorted = urls.sorted {
            ($0.filter { $0 == "/" }.count, $0) < ($1.filter { $0 == "/" }.count, $1)
        }
        XCTAssertEqual(sorted, ["plata://home", "plata://a/b", "plata://a/b/c"])
    }

    func testRouteTokensNormalizeSegments() {
        XCTAssertEqual(DeeplinkHarvest.routeTokens(of: "plata://payments/top_up"), ["payments", "topup"])
        XCTAssertEqual(DeeplinkHarvest.routeTokens(of: "plata://msi-to-convert"), ["msitoconvert"])
        XCTAssertEqual(DeeplinkHarvest.routeTokens(of: "plata://"), [])
        XCTAssertEqual(DeeplinkHarvest.routeTokens(of: "no scheme"), [])
    }

    // Attribution is static: the route's tokens must all appear in the
    // screen's name — the crawl never opens a URL to find out where it lands.
    func testScreenIndexMatchesRouteTokensToScreenNames() {
        let names = ["MainScreenV2View", "InvestMainScreen", "ChatScreen"]
        XCTAssertEqual(DeeplinkHarvest.screenIndex(for: "plata://invest", inNames: names), 1)
        XCTAssertEqual(DeeplinkHarvest.screenIndex(for: "plata://chat", inNames: names), 2)
        XCTAssertNil(DeeplinkHarvest.screenIndex(for: "plata://permissions", inNames: names))
    }

    // Multi-segment routes must match every segment, underscores and case
    // notwithstanding — half a match is a different screen.
    func testScreenIndexRequiresEveryToken() {
        let names = ["PaymentsTopUpScreen", "TopUpScreen"]
        XCTAssertEqual(DeeplinkHarvest.screenIndex(for: "plata://payments/top_up", inNames: names), 0)
        XCTAssertNil(DeeplinkHarvest.screenIndex(for: "plata://payments/transfer", inNames: names))
    }

    // Of several candidates the shortest name wins — the more general screen
    // for the more general route; an exact tie is ambiguity and attributes
    // nothing.
    func testScreenIndexPrefersShortestNameAndSkipsTies() {
        XCTAssertEqual(
            DeeplinkHarvest.screenIndex(for: "plata://payments", inNames: ["BillPaymentsCategoryScreen", "MainPaymentsScreen"]),
            1
        )
        XCTAssertNil(DeeplinkHarvest.screenIndex(for: "plata://chat", inNames: ["ChatScreenA", "ChatScreenB"]))
    }
}
