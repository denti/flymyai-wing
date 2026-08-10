import XCTest
@testable import LidwingCore

/// The strings are the product's whole visible surface, and a translator will never see the
/// code around them. These tests hold the catalogue to the rules that make it translatable.
final class StringsTests: XCTestCase {

    override func tearDown() {
        Strings.localiser = nil
        super.tearDown()
    }

    func testKeysAreUniqueAndNamespaced() {
        let keys = StringKey.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "two entries share a key")
        for key in keys {
            XCTAssertTrue(key.contains("."), "\(key) has no namespace")
            XCTAssertFalse(key.contains(" "), "\(key) has a space")
            XCTAssertTrue(key.allSatisfy { $0.isASCII }, "\(key) is not ASCII")
        }
    }

    /// Interpolation must be positional, or a translation cannot reorder the arguments — and
    /// reordering is exactly what translation does.
    func testEveryPlaceholderIsPositional() {
        for entry in StringKey.all {
            let text = entry.english
            guard text.contains("%") else { continue }
            // Every specifier is either a positional one (%1$@) or a doubled literal percent.
            var scanner = text.startIndex
            while let percent = text[scanner...].firstIndex(of: "%") {
                let next = text.index(after: percent)
                guard next < text.endIndex else {
                    return XCTFail("\(entry.key) ends with a bare percent")
                }
                if text[next] == "%" {
                    scanner = text.index(after: next)
                    continue
                }
                XCTAssertTrue(text[next].isNumber,
                              "\(entry.key) uses a non-positional specifier: \(text)")
                guard let dollar = text[next...].firstIndex(of: "$") else {
                    return XCTFail("\(entry.key) has a positional index with no $: \(text)")
                }
                scanner = text.index(after: dollar)
            }
        }
    }

    /// Style rules from the craft spec, enforced rather than remembered.
    func testTypography() {
        for entry in StringKey.all {
            XCTAssertFalse(entry.english.contains("\u{2014}"), "em dash in \(entry.key)")
            XCTAssertFalse(entry.english.contains("\u{2013}"), "en dash in \(entry.key)")
            XCTAssertFalse(entry.english.contains("..."),
                           "three periods instead of U+2026 in \(entry.key)")
            XCTAssertFalse(entry.english.isEmpty, "\(entry.key) has no text")
        }
    }

    /// A string with a placeholder is meaningless to a translator without one.
    func testEveryStringWithAPlaceholderExplainsIt() {
        for entry in StringKey.all where entry.english.contains("$@")
            || entry.english.contains("$lld") {
            XCTAssertFalse(entry.comment.isEmpty,
                           "\(entry.key) interpolates something and says nothing about what")
        }
    }

    // MARK: lookup

    func testTheEnglishTextIsUsedWhenNoCatalogueIsPresent() {
        Strings.localiser = nil
        XCTAssertEqual(Strings.text("menu.quit", "Quit Lidwing"), "Quit Lidwing")
    }

    func testACatalogueOverridesIt() {
        Strings.localiser = { key, fallback in
            key == "menu.quit" ? "Завершить Lidwing" : fallback
        }
        XCTAssertEqual(Strings.text("menu.quit", "Quit Lidwing"), "Завершить Lidwing")
        XCTAssertEqual(Strings.text("menu.about", "About Lidwing"), "About Lidwing")
    }

    func testPositionalArgumentsCanBeReorderedByATranslation() {
        // The whole reason for positional specifiers: this translation puts the pid first.
        Strings.localiser = { key, fallback in
            key == "menu.foreign.detail" ? "pid %2$lld (%1$@) - Lidwing stood down." : fallback
        }
        let rendered = Strings.text("menu.foreign.detail", "%1$@ (pid %2$lld) - Lidwing stood down.",
                                    "Amphetamine", 812)
        XCTAssertEqual(rendered, "pid 812 (Amphetamine) - Lidwing stood down.")
    }

    /// A missing key must be visible, not blank. A blank menu row is the kind of bug nobody
    /// reports because it looks like nothing at all.
    func testAMissingKeyFallsBackRatherThanVanishing() {
        Strings.localiser = { _, fallback in fallback }
        XCTAssertEqual(Strings.text("does.not.exist", "Fallback text"), "Fallback text")
    }
}
