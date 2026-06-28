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
    let autoAdvancePagesWithSpeech: Bool
    let backgroundColor: UIColor
    let initialPageIndex: Int?
    var onTap: () -> Void
    var onSelectionChanged: (Bool) -> Void
    var onVisiblePageChanged: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
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

        if let initialPageIndex, document.page(at: initialPageIndex) != nil {
            // Layout fires PDFViewPageChanged for page 0 before the restore lands; persistence
            // stays suppressed until a page-change event confirms the target page (the page-changed
            // observer re-issues the navigation if layout swallowed it).
            context.coordinator.pendingInitialPageIndex = initialPageIndex
            let coordinator = context.coordinator
            // PDFView ignores go(to:) until it has laid out; defer one runloop turn.
            DispatchQueue.main.async { [weak pdfView] in
                coordinator.attemptInitialNavigation(in: pdfView)
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
        context.coordinator.applyHighlight(
            highlight,
            autoAdvancePagesWithSpeech: autoAdvancePagesWithSpeech,
            in: pdfView
        )
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
        var pendingInitialPageIndex: Int?

        private struct PendingSpeechFollow {
            let pageIndex: Int
            let bounds: CGRect
            var attempts: Int
        }

        private var initialNavigationAttempts = 0
        private var currentAnnotations: [PDFAnnotation] = []
        private var lastHighlight: PDFWordHighlight?
        private var lastAutoAdvancePagesWithSpeech: Bool?
        private var pendingSpeechFollow: PendingSpeechFollow?
        private var speechFollowRetryScheduled = false
        private let maxSpeechFollowAttempts = 5
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
                          let document = pdfView.document,
                          let page = pdfView.currentPage else { return }
                    let pageIndex = document.index(for: page)

                    if let pending = self.pendingInitialPageIndex {
                        if pageIndex == pending {
                            self.pendingInitialPageIndex = nil
                        } else {
                            self.initialNavigationAttempts += 1
                            if self.initialNavigationAttempts >= 5 {
                                self.pendingInitialPageIndex = nil
                            } else {
                                self.attemptInitialNavigation(in: pdfView)
                            }
                        }
                        return
                    }
                    if self.retryPendingSpeechFollow(in: pdfView) {
                        if self.pendingSpeechFollow != nil {
                            return
                        }
                    }
                    self.onVisiblePageChanged(pageIndex)
                }
            })
        }

        @objc func handleTap() {
            onTap()
        }

        func attemptInitialNavigation(in pdfView: PDFView?) {
            guard let pdfView, let pending = pendingInitialPageIndex,
                  let document = pdfView.document,
                  let page = document.page(at: pending) else {
                pendingInitialPageIndex = nil
                return
            }
            pdfView.go(to: page)
            if let current = pdfView.currentPage, document.index(for: current) == pending {
                pendingInitialPageIndex = nil
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Updates transient word annotations and optionally follows speech across pages.
        func applyHighlight(
            _ highlight: PDFWordHighlight?,
            autoAdvancePagesWithSpeech: Bool,
            in pdfView: PDFView
        ) {
            guard highlight != lastHighlight ||
                    autoAdvancePagesWithSpeech != lastAutoAdvancePagesWithSpeech else {
                if autoAdvancePagesWithSpeech {
                    retryPendingSpeechFollow(in: pdfView)
                }
                return
            }
            lastHighlight = highlight
            lastAutoAdvancePagesWithSpeech = autoAdvancePagesWithSpeech

            for annotation in currentAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            currentAnnotations = []

            guard let highlight,
                  let document = pdfView.document,
                  let page = document.page(at: highlight.pageIndex),
                  let selection = page.selection(for: highlight.range) else {
                pendingSpeechFollow = nil
                return
            }

            // Line fragments avoid union boxes that cover gaps for wrapped or hyphen-merged words.
            for lineSelection in selection.selectionsByLine() {
                let bounds = lineSelection.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemBlue.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
                currentAnnotations.append(annotation)
            }

            guard autoAdvancePagesWithSpeech else {
                pendingSpeechFollow = nil
                return
            }
            guard pdfView.currentPage != page else {
                pendingSpeechFollow = nil
                return
            }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else {
                pendingSpeechFollow = nil
                return
            }
            followSpeech(toPageAt: highlight.pageIndex, bounds: bounds.insetBy(dx: -20, dy: -60), in: pdfView)
        }

        /// Retries a remembered speech-follow target after PDFKit swallows a page jump.
        @discardableResult
        func retryPendingSpeechFollow(in pdfView: PDFView) -> Bool {
            attemptPendingSpeechFollow(in: pdfView, scheduleFollowUp: false)
        }

        private func followSpeech(toPageAt pageIndex: Int, bounds: CGRect, in pdfView: PDFView) {
            pendingSpeechFollow = PendingSpeechFollow(pageIndex: pageIndex, bounds: bounds, attempts: 0)
            attemptPendingSpeechFollow(in: pdfView, scheduleFollowUp: true)
        }

        @discardableResult
        private func attemptPendingSpeechFollow(in pdfView: PDFView, scheduleFollowUp: Bool) -> Bool {
            guard var pending = pendingSpeechFollow else { return false }
            guard let document = pdfView.document,
                  let page = document.page(at: pending.pageIndex) else {
                pendingSpeechFollow = nil
                return false
            }
            if pdfView.currentPage == page {
                pendingSpeechFollow = nil
                return true
            }
            guard pending.attempts < maxSpeechFollowAttempts else {
                pendingSpeechFollow = nil
                return false
            }

            pending.attempts += 1
            pendingSpeechFollow = pending
            pdfView.go(to: pending.bounds, on: page)

            if scheduleFollowUp {
                schedulePendingSpeechFollowRetry(in: pdfView)
            }
            return true
        }

        private func schedulePendingSpeechFollowRetry(in pdfView: PDFView) {
            guard !speechFollowRetryScheduled else { return }
            speechFollowRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak pdfView] in
                Task { @MainActor in
                    guard let self, let pdfView else { return }
                    self.speechFollowRetryScheduled = false
                    self.attemptPendingSpeechFollow(in: pdfView, scheduleFollowUp: true)
                }
            }
        }
    }
}
