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

/// A translation that silently loses a key shows English in one menu row and Russian in the
/// next, which reads as a bug in the app rather than a gap in the catalogue.
final class TranslationTests: XCTestCase {

    override func tearDown() {
        Strings.localiser = nil
        super.tearDown()
    }

    func testEveryCatalogueCoversEveryKey() {
        let expected = Set(StringKey.all.map(\.key))
        for (language, catalogue) in Translations.catalogues {
            let provided = Set(catalogue.keys)
            let missing = expected.subtracting(provided).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.joined(separator: ", "))")

            let extra = provided.subtracting(expected).sorted()
            XCTAssertTrue(extra.isEmpty,
                          "\(language) has keys nothing reads: \(extra.joined(separator: ", "))")
        }
    }

    /// A translation that drops or renumbers a placeholder produces a crash or a wrong number
    /// at runtime, in a string that is usually about a safety limit.
    func testEveryTranslationKeepsItsPlaceholders() {
        let english = Dictionary(uniqueKeysWithValues: StringKey.all.map { ($0.key, $0.english) })
        for (language, catalogue) in Translations.catalogues {
            for (key, translated) in catalogue {
                guard let source = english[key] else { continue }
                XCTAssertEqual(placeholders(in: translated), placeholders(in: source),
                               "\(language)/\(key): placeholders differ")
            }
        }
    }

    private func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        var index = text.startIndex
        while let percent = text[index...].firstIndex(of: "%") {
            let after = text.index(after: percent)
            guard after < text.endIndex else { break }
            if text[after] == "%" {
                index = text.index(after: after)
                continue
            }
            if let dollar = text[after...].firstIndex(of: "$"),
               text.distance(from: after, to: dollar) <= 2 {
                let end = text.index(dollar, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                var type = String(text[dollar..<end])
                // %1$lld and %1$@ - keep enough to distinguish a number from a string.
                var cursor = end
                while cursor < text.endIndex, "ld@".contains(text[cursor]) {
                    type.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                found.insert(String(text[percent..<after]) + type)
                index = cursor
            } else {
                index = after
            }
        }
        return found
    }

    func testLanguageMatchingIgnoresRegionAndCase() {
        XCTAssertNotNil(Translations.catalogue(for: ["ru-RU"]))
        XCTAssertNotNil(Translations.catalogue(for: ["ru_RU"]))
        XCTAssertNotNil(Translations.catalogue(for: ["RU"]))
        XCTAssertNotNil(Translations.catalogue(for: ["fr", "ru"]), "should fall through to ru")
        XCTAssertNil(Translations.catalogue(for: ["fr-CA"]))
        XCTAssertNil(Translations.catalogue(for: []))
    }

    func testTheRussianMenuActuallyRenders() {
        Strings.localiser = Translations.localiser(for: ["ru"])
        XCTAssertEqual(Strings.text("menu.quit", "Quit Lidwing"), "Завершить Lidwing")
        XCTAssertEqual(Strings.text("menu.battery", "Awake - battery %1$lld%%", Int64(23)),
                       "Не спит - батарея 23%")
        // A key with no translation still renders in English rather than vanishing.
        XCTAssertEqual(Strings.text("not.translated", "English text"), "English text")
    }
}
