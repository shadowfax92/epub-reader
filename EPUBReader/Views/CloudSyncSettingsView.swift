import SwiftUI

/// Surfaces iCloud reading-progress sync: overall iCloud status, a manual "Sync Now",
/// and a per-book list of synced page + when it last changed. Pushed from `SettingsView`.
struct CloudSyncSettingsView: View {
    @EnvironmentObject var bookStore: BookStore
    @State private var isSyncing = false

    var body: some View {
        let isCloudAvailable = bookStore.isCloudAvailable
        Form {
            statusSection(isCloudAvailable: isCloudAvailable)
            booksSection
        }
        .navigationTitle("Cloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func statusSection(isCloudAvailable: Bool) -> some View {
        Section {
            HStack(spacing: 12) {
                icloudIcon(isCloudAvailable: isCloudAvailable)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCloudAvailable ? "iCloud Sync On" : "iCloud Unavailable")
                    Text(availabilityDetail(isCloudAvailable: isCloudAvailable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            HStack {
                Text("Last Synced")
                Spacer()
                Text(lastSyncedLabel)
                    .foregroundStyle(.secondary)
            }

            Button(action: syncNow) {
                HStack(spacing: 8) {
                    Spacer()
                    if isSyncing {
                        ProgressView()
                        Text("Syncing…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync Now").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(isSyncing)
        } footer: {
            Text("Reading progress syncs automatically as you read. Sync Now uploads this device's latest progress to iCloud.")
        }
    }

    @ViewBuilder
    private var booksSection: some View {
        Section("Synced Books") {
            let statuses = bookStore.cloudSyncStatuses()
            if statuses.isEmpty {
                Text("No reading progress yet. Open a book to start syncing.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statuses) { status in
                    CloudSyncBookRow(status: status)
                }
            }
        }
    }

    private func icloudIcon(isCloudAvailable: Bool) -> some View {
        Image(systemName: isCloudAvailable ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
                isCloudAvailable ? Color.blue : Color.orange,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }

    private func availabilityDetail(isCloudAvailable: Bool) -> String {
        isCloudAvailable
            ? "Your reading position syncs across your devices."
            : "Sign in to iCloud in Settings to sync your reading position."
    }

    private var lastSyncedLabel: String {
        guard let date = bookStore.lastCloudSyncDate else { return "Never" }
        return relativeDateString(date, style: .full)
    }

    private func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        Task { @MainActor in
            bookStore.forceCloudSync()
            // forceCloudSync is instant; hold the spinner briefly so the action reads as work.
            try? await Task.sleep(for: .milliseconds(500))
            isSyncing = false
        }
    }
}

private struct CloudSyncBookRow: View {
    let status: BookCloudSyncStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.book.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [status.pageLabel]
        switch status.state {
        case .upToDate:
            if let date = status.updatedAt {
                parts.append("Synced \(relativeDateString(date, style: .abbreviated))")
            }
        case .updateAvailable:
            parts.append("Newer version in iCloud")
        case .pendingUpload:
            parts.append("Waiting to upload")
        }
        return parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch status.state {
        case .upToDate: return "checkmark.icloud"
        case .updateAvailable: return "arrow.down.circle"
        case .pendingUpload: return "arrow.up.circle"
        }
    }

    private var iconColor: Color {
        switch status.state {
        case .upToDate: return .green
        case .updateAvailable: return .blue
        case .pendingUpload: return .orange
        }
    }
}

/// Foundation's `RelativeDateTimeFormatter` isn't `Sendable`, so build one per call
/// instead of caching it in a `static let` (cheap for a settings list).
private func relativeDateString(_ date: Date, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = style
    return formatter.localizedString(for: date, relativeTo: Date())
}
