import SwiftUI
import UIKit
import PDFKit

struct PDFWordHighlight: Equatable {
    let pageIndex: Int
    let range: NSRange
}

/// Imperative handle for user-triggered navigation (page jumps, scroll-to-word) and
/// selection reads — things that don't fit the declarative `highlight` prop flow.
@MainActor
final class PDFViewProxy {
    weak var pdfView: PDFView?

    func goToPage(_ pageIndex: Int) {
        guard let pdfView, let document = pdfView.document,
              let page = document.page(at: pageIndex) else { return }
        pdfView.go(to: page)
    }

    func scrollTo(pageIndex: Int, range: NSRange) {
        guard let pdfView, let document = pdfView.document,
              let page = document.page(at: pageIndex),
              let selection = page.selection(for: range) else { return }
        let bounds = selection.bounds(for: page)
        guard !bounds.isNull else { return }
        pdfView.go(to: bounds.insetBy(dx: -20, dy: -60), on: page)
    }

    func currentSelectionInfo() -> (text: String, pageIndex: Int, startOffset: Int?)? {
        guard let pdfView, let document = pdfView.document,
              let selection = pdfView.currentSelection,
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else { return nil }

        // Selection start offset disambiguates repeated phrases; PDFKit has no direct
        // selection→range API, so probe the character index at the first line's leading edge.
        var startOffset: Int?
        if let firstLine = selection.selectionsByLine().first, firstLine.pages.first == page {
            let bounds = firstLine.bounds(for: page)
            let index = page.characterIndex(at: CGPoint(x: bounds.minX + 1, y: bounds.midY))
            if index >= 0 { startOffset = index }
        }
        return (text, document.index(for: page), startOffset)
    }

    func clearSelection() {
        pdfView?.clearSelection()
    }
}

struct PDFKitReaderView: UIViewRepresentable {
    let document: PDFDocument
    let proxy: PDFViewProxy
    let highlight: PDFWordHighlight?
    let backgroundColor: UIColor
    let initialPageIndex: Int?
    var onTap: () -> Void
    var onSelectionChanged: (Bool) -> Void
    var onVisiblePageChanged: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = backgroundColor
        pdfView.document = document

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        pdfView.addGestureRecognizer(tap)

        context.coordinator.observe(pdfView)
        proxy.pdfView = pdfView

        if let initialPageIndex, let page = document.page(at: initialPageIndex) {
            // Layout fires PDFViewPageChanged for page 0 before the restore lands;
            // suppress persistence until then so the saved page isn't clobbered.
            context.coordinator.initialNavigationPending = true
            let coordinator = context.coordinator
            // PDFView ignores go(to:) until it has laid out; defer one runloop turn.
            DispatchQueue.main.async {
                pdfView.go(to: page)
                coordinator.initialNavigationPending = false
            }
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onVisiblePageChanged = onVisiblePageChanged

        if pdfView.backgroundColor != backgroundColor {
            pdfView.backgroundColor = backgroundColor
        }
        context.coordinator.applyHighlight(highlight, in: pdfView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap,
                    onSelectionChanged: onSelectionChanged,
                    onVisiblePageChanged: onVisiblePageChanged)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        var onSelectionChanged: (Bool) -> Void
        var onVisiblePageChanged: (Int) -> Void
        var initialNavigationPending = false

        private var currentAnnotations: [PDFAnnotation] = []
        private var lastHighlight: PDFWordHighlight?
        private var lastNavigatedPageIndex: Int?
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        init(onTap: @escaping () -> Void,
             onSelectionChanged: @escaping (Bool) -> Void,
             onVisiblePageChanged: @escaping (Int) -> Void) {
            self.onTap = onTap
            self.onSelectionChanged = onSelectionChanged
            self.onVisiblePageChanged = onVisiblePageChanged
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(_ pdfView: PDFView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] notification in
                let pdfView = notification.object as? PDFView
                Task { @MainActor in
                    guard let self, let pdfView else { return }
                    let text = pdfView.currentSelection?.string ?? ""
                    self.onSelectionChanged(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] notification in
                let pdfView = notification.object as? PDFView
                Task { @MainActor in
                    guard let self, let pdfView,
                          !self.initialNavigationPending,
                          let document = pdfView.document,
                          let page = pdfView.currentPage else { return }
                    self.onVisiblePageChanged(document.index(for: page))
                }
            })
        }

        @objc func handleTap() {
            onTap()
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Swaps the transient word annotations; navigates only when the word
        /// crosses onto a different page (mirrors the EPUB chapter-change rule).
        /// One annotation per line fragment so hyphen-merged words spanning a line
        /// break don't get a unioned box covering both full lines.
        func applyHighlight(_ highlight: PDFWordHighlight?, in pdfView: PDFView) {
            guard highlight != lastHighlight else { return }
            lastHighlight = highlight

            for annotation in currentAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            currentAnnotations = []

            guard let highlight,
                  let document = pdfView.document,
                  let page = document.page(at: highlight.pageIndex),
                  let selection = page.selection(for: highlight.range) else { return }

            for lineSelection in selection.selectionsByLine() {
                let bounds = lineSelection.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemBlue.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
                currentAnnotations.append(annotation)
            }

            if lastNavigatedPageIndex != highlight.pageIndex {
                lastNavigatedPageIndex = highlight.pageIndex
                let bounds = selection.bounds(for: page)
                if pdfView.currentPage != page, !bounds.isNull {
                    pdfView.go(to: bounds.insetBy(dx: -20, dy: -60), on: page)
                }
            }
        }
    }
}
