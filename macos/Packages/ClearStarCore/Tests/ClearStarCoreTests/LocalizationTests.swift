import Foundation
import Testing
@testable import ClearStarCore

/// A repó közös nyelvi mappája: macos/Packages/ClearStarCore/Tests/ClearStarCoreTests → shared/Languages.
private let languagesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("shared/Languages")

private func table(_ code: String) throws -> [String: String] {
    try Strings.parse(Data(contentsOf: languagesDir.appendingPathComponent("\(code).json")))
}

@Test func builtInLanguagesHaveTheSameKeys() throws {
    let hu = try table("hu"), en = try table("en")
    #expect(Set(hu.keys).subtracting(en.keys).isEmpty)
    #expect(Set(en.keys).subtracting(hu.keys).isEmpty)
    // A helyőrzők száma is egyezzen (különben a formázás elszáll).
    let placeholder = /\{\d/
    for (k, v) in hu {
        #expect(v.matches(of: placeholder).count == (en[k] ?? "").matches(of: placeholder).count, "\(k)")
    }
}

@Test func everyStepHasANameInBothLanguages() {
    for code in ["hu", "en"] {
        let s = Strings(language: code, directory: languagesDir)
        #expect(s.language == code)
        for step in StepId.allCases { #expect(s.has("step.\(step.languageKey).name"), "\(code): \(step)") }
        for group in StepGroup.allCases { #expect(s.has("group.\(group.rawValue)")) }
    }
    #expect(Strings(language: "hu", directory: languagesDir).t("step.load.name") == "Képek betöltése")
}

@Test func missingLanguageFallsBackToEnglish() {
    let s = Strings(language: "xx", directory: languagesDir)
    #expect(s.language == "en")
    #expect(s.t("no.such.key") == "no.such.key")
}

@Test func dotNetPlaceholders() {
    let en = Locale(identifier: "en"), hu = Locale(identifier: "hu")
    #expect(DotNetFormat.format("{0} of {1}", [3, 16], locale: en) == "3 of 16")
    #expect(DotNetFormat.format("{0:0.0} s", [1.25], locale: en) == "1.3 s")
    #expect(DotNetFormat.format("{0:0.00}", [2.5], locale: hu) == "2,50")
    #expect(DotNetFormat.format("{0:0.#}", [2.0], locale: en) == "2")
    #expect(DotNetFormat.format("{0:0}", [2.6], locale: en) == "3")
    #expect(DotNetFormat.format("{0:+0.00;−0.00;0}", [0.5], locale: en) == "+0.50")
    #expect(DotNetFormat.format("{0:+0.00;−0.00;0}", [-0.5], locale: en) == "−0.50")
    #expect(DotNetFormat.format("{0:+0.00;−0.00;0}", [0.0], locale: en) == "0")
    #expect(DotNetFormat.format("{0:P0}", [0.25], locale: en) == "25%")
    #expect(DotNetFormat.format("{{{0}}}", [1], locale: en) == "{1}")
}

@Test func arraysBecomePipeSeparatedLists() throws {
    let s = Strings(language: "en", table: try Strings.parse(Data(#"{"a":{"ticks":["Low","High"]}}"#.utf8)))
    #expect(s.a("a.ticks") == ["Low", "High"])
}
