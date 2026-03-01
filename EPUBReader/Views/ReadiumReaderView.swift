import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

struct ReadiumReaderView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    var onSpeakFromSelection: ((Selection) -> Void)?
    var onHighlightSelection: ((Selection) -> Void)?

    func makeUIViewController(context: Context) -> ReaderContainerViewController {
        let container = ReaderContainerViewController(navigator: navigator)
        container.onSpeakFromSelection = onSpeakFromSelection
        container.onHighlightSelection = onHighlightSelection
        return container
    }

    func updateUIViewController(_ vc: ReaderContainerViewController, context: Context) {
        vc.onSpeakFromSelection = onSpeakFromSelection
        vc.onHighlightSelection = onHighlightSelection
    }
}

/// Wraps EPUBNavigatorViewController as a child so custom UIMenuController actions
/// (like "Speak from Here") resolve through the responder chain.
@MainActor
class ReaderContainerViewController: UIViewController {
    let navigator: EPUBNavigatorViewController
    var onSpeakFromSelection: ((Selection) -> Void)?
    var onHighlightSelection: ((Selection) -> Void)?

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)
    }

    @objc func speakFromHere(_ sender: Any?) {
        guard let selection = navigator.currentSelection else { return }
        onSpeakFromSelection?(selection)
    }

    @objc func highlightSelection(_ sender: Any?) {
        guard let selection = navigator.currentSelection else { return }
        onHighlightSelection?(selection)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(speakFromHere(_:)) || action == #selector(highlightSelection(_:)) {
            return navigator.currentSelection != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
