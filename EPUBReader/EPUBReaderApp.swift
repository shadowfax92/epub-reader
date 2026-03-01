import SwiftUI

@main
struct EPUBReaderApp: App {
    @StateObject private var bookStore = BookStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LibraryView()
            }
            .environmentObject(bookStore)
        }
    }
}
