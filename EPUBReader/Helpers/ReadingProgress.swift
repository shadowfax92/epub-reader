import Foundation
import ReadiumShared

/// Whole-book reading-progress math for the Library "percent read" indicator.
///
/// Pure and synchronous so it can be unit-tested without the reader UI. All fractions
/// are clamped to 0...1. The two formats derive progress differently — EPUB from the
/// saved Readium locator, PDF from the page index + total — but both answer
/// "how far through the whole book am I".
enum ReadingProgress {
    /// EPUB progress = the saved locator's whole-publication `totalProgression`.
    ///
    /// Returns nil when there's no locator, it can't be parsed, or `totalProgression`
    /// is absent (e.g. the locator was saved before Readium finished computing the
    /// publication's positions). We deliberately do **not** fall back to the
    /// chapter-relative `progression`, which would overstate progress.
    static func fraction(epubLocatorJSON json: String?) -> Double? {
        guard let json, !json.isEmpty,
              let locator = try? Locator(jsonString: json),
              let total = locator.locations.totalProgression else { return nil }
        return clamp(total)
    }

    /// PDF progress = page reached / total. `pageIndex` is 0-based, so the last page
    /// (`pageIndex == pageCount - 1`) reads as 100%.
    static func fraction(pdfPageIndex pageIndex: Int?, pageCount: Int?) -> Double? {
        guard let pageIndex, let pageCount, pageCount > 0 else { return nil }
        return clamp(Double(pageIndex + 1) / Double(pageCount))
    }

    /// Rounds a 0...1 fraction to an integer 0...100, or nil when there's no progress.
    static func percent(_ fraction: Double?) -> Int? {
        guard let fraction else { return nil }
        return Int((clamp(fraction) * 100).rounded())
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
