import Foundation

/// Splits report prose into the paragraphs the model actually wrote.
///
/// The pipeline asks for "2–4 paragraphs" and the model separates them with a
/// blank line. Rendering that string as one `Text` collapses the distinction:
/// the gap between paragraphs becomes the same 5pt as the gap between lines,
/// so a three-paragraph overview reads as one wall of copy — which is exactly
/// what a deep research body must not look like.
///
/// Extracted from the view so the split rules can be asserted without layout.
enum ResearchProseParagraphs {
    /// Paragraphs of `text`, in order, with surrounding whitespace trimmed.
    ///
    /// A blank line separates paragraphs. A single newline inside a paragraph
    /// is kept as-is: the model sometimes wraps a list or a quotation that way,
    /// and treating it as a paragraph break would fabricate structure.
    static func split(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// True when there is more than one paragraph, so a caller can pick the
    /// stacked layout instead of the single-run one without splitting twice.
    static func hasMultipleParagraphs(_ text: String) -> Bool {
        split(text).count > 1
    }
}
