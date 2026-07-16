import Foundation

/// Why a prompt could not be loaded from the bundle.
public enum PromptError: Error, Equatable {
    /// The named prompt resource is absent, unreadable, or empty.
    case missing(String)
}

/// The two organization prompts (ADR-0001): pass 1 annotates, pass 2 rewrites.
/// They are `claude`'s `--system-prompt` value on each pass — the slot where the
/// CLI prompt-caches them (`docs/research/claude-cli-shell-out-contract.md`).
///
/// The calibrated text ships as bundled `.txt` resources so the app never depends
/// on a file outside its own bundle; `bundled()` loads them. Tests inject strings
/// directly through `init`, so the organizer is testable without the bundle.
public struct Prompts: Equatable, Sendable {
    /// Pass 1 — the annotator. Marks four things and rewrites nothing.
    public let pass1: String
    /// Pass 2 — the rewriter. Applies the marks mechanically, then cleans up.
    public let pass2: String

    public init(pass1: String, pass2: String) {
        self.pass1 = pass1
        self.pass2 = pass2
    }

    /// Load both prompts from the framework bundle (`pass1.txt`, `pass2.txt`).
    /// Throws `missing` if either resource is absent or empty — a build/packaging
    /// error the app should surface, never silently organize without a prompt.
    public static func bundled() throws(PromptError) -> Prompts {
        Prompts(pass1: try load("pass1"), pass2: try load("pass2"))
    }

    private static func load(_ name: String) throws(PromptError) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        else {
            throw PromptError.missing(name)
        }
        return text
    }
}
