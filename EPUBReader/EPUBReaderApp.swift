import SwiftUI

@main
struct EPUBReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bookStore = BookStore()
    @StateObject private var syncService = SyncService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LibraryView()
            }
            .environmentObject(bookStore)
            .environmentObject(syncService)
            .task {
                syncService.bookStore = bookStore
                await syncService.checkiCloudStatus()
                if syncService.iCloudAvailable {
                    await syncService.performFullSync()
                    await syncService.setupSubscriptions()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await syncService.checkiCloudStatus()
                        if syncService.iCloudAvailable {
                            await syncService.performFullSync()
                        }
                    }
                }
            }
        }
    }
}
