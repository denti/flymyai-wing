import XCTest
@testable import LidwingCore

/// The strings are the product's whole visible surface, and a translator will never see the
/// code around them. These tests hold the catalogue to the rules that make it translatable.
final class StringsTests: XCTestCase {

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
        XCTAssertEqual(Strings.text("menu.quit", "Quit Lidwing"), "Quit Lidwing")
    }

    /// The app is English, permanently. A Russian catalogue used to be selected from
    /// `Locale.preferredLanguages` and it shipped: `Выключено` is in the v0.1.0 binary, so on a
    /// Russian-language Mac the interface really was Russian. There is no hook to substitute
    /// anything now, and this asserts that property rather than the absence of a file.
    func testTheTextIsAlwaysTheEnglishGivenAtTheCallSite() {
        XCTAssertEqual(Strings.text("menu.quit", "Quit Lidwing"), "Quit Lidwing")
        XCTAssertEqual(Strings.text("menu.foreign.detail",
                                    "%1$@ (pid %2$lld) - Lidwing stood down.", "Amphetamine", 812),
                       "Amphetamine (pid 812) - Lidwing stood down.")
    }

    /// No string this product ships may contain a non-English letter. Typographic punctuation is
    /// deliberate and stays - a real ellipsis, a proper apostrophe - but a Cyrillic or accented
    /// letter means a translation has crept back in.
    func testNoShippedStringContainsANonEnglishLetter() {
        for entry in StringKey.all {
            for scalar in entry.english.unicodeScalars where scalar.value > 127 {
                // `isAlphabetic` rather than `CharacterSet.letters`, which also matches the
                // variation selector in the warning glyph. Symbols and typographic punctuation
                // are deliberate here; another alphabet is not.
                XCTAssertFalse(scalar.properties.isAlphabetic,
                               "\(entry.key) contains a non-English letter: \(entry.english)")
            }
        }
    }

    /// A missing key must be visible, not blank. A blank menu row is the kind of bug nobody
    /// reports because it looks like nothing at all.
    func testAMissingKeyFallsBackRatherThanVanishing() {
        XCTAssertEqual(Strings.text("does.not.exist", "Fallback text"), "Fallback text")
    }
}
