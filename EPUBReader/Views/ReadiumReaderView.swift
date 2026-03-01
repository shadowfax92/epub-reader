import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

struct ReadiumReaderView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
