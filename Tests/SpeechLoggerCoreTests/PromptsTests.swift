import Foundation
import Testing

@testable import SpeechLoggerCore

/// The prompts ship as bundled resources so the app loads them from its own bundle,
/// never a path in `.scratch` (issue #18). If bundling regresses, organization would
/// silently have no prompt — so this asserts both resources load, are non-empty, and
/// are the calibrated annotate/rewrite prompts (by a distinctive marker in each).
struct PromptsTests {
    @Test("both prompts load from the bundle, non-empty")
    func bundledPromptsLoad() throws {
        let prompts = try Prompts.bundled()
        #expect(!prompts.pass1.isEmpty)
        #expect(!prompts.pass2.isEmpty)
    }

    @Test("pass 1 is the annotator and pass 2 is the rewriter — the marks and the noise rule survive")
    func bundledPromptsAreTheCalibratedOnes() throws {
        let prompts = try Prompts.bundled()
        // Pass 1 defines the four annotation tags and rewrites nothing.
        #expect(prompts.pass1.contains("<del>"))
        #expect(prompts.pass1.contains("<noise>"))
        #expect(prompts.pass1.contains("ANOTADOR"))
        // Pass 2 turns the noise tag into the `[? ... ?]` mark and forbids repair.
        #expect(prompts.pass2.contains("[?"))
        #expect(prompts.pass2.contains("?]"))
    }
}
