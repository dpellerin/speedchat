import Testing
import Foundation
@testable import ChatCore

@Test func citationMetadataResolvesPrivateMarkersToClickableMarkdown() {
    let sources = RenderNormalizer.citationSources(from: [
        ["ref_id": "turn0search1", "title": "Apple security releases", "url": "https://support.apple.com/releases"],
    ])
    #expect(
        RenderNormalizer.resolveCitations("Current release. \u{E200}cite\u{E202}turn0search1\u{E201}", sources: sources)
        == "Current release. [Apple security releases](https://support.apple.com/releases)"
    )
}

@Test func multipleCitationsStayDistinctAndUnresolvedMarkersDisappear() {
    let sources = RenderNormalizer.citationSources(from: [
        ["ref_id": "turn0search0", "title": "One", "url": "https://example.com/one"],
        ["ref_id": "turn0search1", "title": "Two", "url": "https://example.com/two"],
    ])
    #expect(
        RenderNormalizer.resolveCitations("Claim. \u{E200}cite\u{E202}turn0search0\u{E202}turn0search1\u{E201}", sources: sources)
        == "Claim. [1](https://example.com/one) [2](https://example.com/two)"
    )
    #expect(RenderNormalizer.resolveCitations("Claim. \u{E200}cite\u{E202}turn9search9\u{E201}", sources: sources) == "Claim.")
}

@Test func streamingCitationsBecomeLinksAsSoonAsMarkerCompletes() {
    var stream = StreamingCitationResolver()
    let sources = [CitationSource(refId: "turn0search1", url: "https://example.com", title: "Reference")]
    #expect(stream.push("Claim. \u{E200}cite\u{E202}turn0", sources: sources) == "Claim. ")
    #expect(stream.push("search1", sources: sources) == "")
    #expect(stream.push("\u{E201} More.", sources: sources) == "[Reference](https://example.com) More.")
}

@Test func streamingLinksReachUIOnlyWhenFullyFormed() {
    var stream = StreamingLinkResolver()
    #expect(stream.push("See [Open") == "See ")
    #expect(stream.push("AI](https://developers.") == "")
    #expect(stream.push("openai.com/docs) now.") == "[OpenAI](https://developers.openai.com/docs) now.")
}

@Test func streamingImageMarkupBecomesOrdinaryCompletedLink() {
    var stream = StreamingLinkResolver()
    #expect(stream.push("Photo: ![Chevrolet](https://example.") == "Photo: ")
    #expect(stream.push("com/car.png)") == "[Chevrolet](https://example.com/car.png)")
}

@Test func streamingUnclosedBracketsAcrossNewlinesFlushImmediately() {
    var stream = StreamingLinkResolver()
    #expect(stream.push("const x = arr[\n") == "const x = arr[\n")
    #expect(stream.push("  0\n];") == "  0\n];")
    #expect(stream.push("Call [fn](\narg)") == "Call [fn](\narg)")
}

@Test func commonLatexBecomesReadableUnicode() {
    #expect(RenderNormalizer.formatLatex("x^2 \\pm \\sqrt{b^2 - 4ac}") == "x² ± √(b² - 4ac)")
    #expect(RenderNormalizer.formatLatex("\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}") == "(-b ± √(b² - 4ac))/(2a)")
    #expect(RenderNormalizer.formatLatex("\\sum_{i=1}^{n} i") == "∑ᵢ₌₁ⁿ i")
}

@Test func displayAndInlineMathFormatSafelyWithoutTouchingCurrency() {
    #expect(RenderNormalizer.normalizeMath("Use \\(x^2 + y^2\\).") == "Use x² + y².")
    #expect(RenderNormalizer.normalizeMath("Answer:\n\\[x = \\frac{-b}{2a}\\]") == "Answer:\n\n```math\nx = (-b)/(2a)\n```")
    #expect(RenderNormalizer.normalizeMath("It costs $5 and sometimes $10.") == "It costs $5 and sometimes $10.")
}

@Test func normalizationPreservesFencedCodeIndentationAndLiteralMath() {
    let code = "```python\nif True:\n    print(\"$x^2$\")\n\n\n    print(\"done\")\n```"
    #expect(RenderNormalizer.normalizeAssistantText(code) == code)
}

@Test func normalizationPreservesInlineCodeWhileFormattingSurroundingMath() {
    #expect(RenderNormalizer.normalizeAssistantText("Use `$x^2$` and $y^2$.") == "Use `$x^2$` and y².")
}

@Test func completeNormalizerHandlesCitationsAndMathTogether() {
    let sources = [CitationSource(refId: "turn0view0", url: "https://example.com", title: "Reference")]
    #expect(
        RenderNormalizer.normalizeAssistantText("\\(E = mc^2\\). \u{E200}cite\u{E202}turn0view0\u{E201}", sources: sources)
        == "E = mc². [Reference](https://example.com)"
    )
}
