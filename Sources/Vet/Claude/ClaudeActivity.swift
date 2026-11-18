import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// Something Claude did in Vet (finished a change and set the review order, answered your notes,
/// pointed at a line): a banner in Vet with Show, and a notification when Vet isn't in front.
struct ClaudeEvent: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var path: String?
    var line: Int?
    var noteID: String?
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func setUpClaudeNotifications() {
        guard !SnapshotHook.isTesting else { return } // test builds share the user's notification settings
        UNUserNotificationCenter.current().delegate = self
    }

    /// Claude did something: the banner, and a notification if you're elsewhere.
    func claudeDid(_ title: String, path: String? = nil, line: Int? = nil, noteID: String? = nil) {
        let event = ClaudeEvent(title: title, path: path, line: line, noteID: noteID)
        workspace.claudeEvent = event
        Task {
            try? await Task.sleep(for: .seconds(15))
            if workspace.claudeEvent?.id == event.id { workspace.claudeEvent = nil }
        }
        guard !NSApp.isActive, !SnapshotHook.isTesting else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = Agent.name
            content.body = title
            var info: [String: Any] = [:]
            if let path { info["path"] = path }
            if let line { info["line"] = line }
            if let noteID { info["noteID"] = noteID }
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        }
    }

    /// Takes you to what Claude did: its file, at the line, with its note open.
    func showClaudeEvent(_ event: ClaudeEvent) {
        workspace.claudeEvent = nil
        guard let path = event.path else { return }
        if workspace.review.changes.contains(where: { $0.path == path }) {
            showDiff(path)
            if let id = event.noteID {
                Task {
                    try? await Task.sleep(for: .seconds(0.6)) // the diff loads first
                    workspace.review.diffView.revealNote(id)
                }
            }
        } else if let root = workspace.root {
            showFile(root.appendingPathComponent(path), line: event.line ?? 0)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let event = ClaudeEvent(title: response.notification.request.content.body, path: info["path"] as? String,
                                line: info["line"] as? Int, noteID: info["noteID"] as? String)
        await MainActor.run {
            NSApp.activate()
            showClaudeEvent(event)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [] // in front, the banner in Vet says it
    }
}

/// The banner: what Claude did, and Show.
struct ClaudeBanner: View {
    let app: AppDelegate
    var body: some View {
        if let event = app.workspace.claudeEvent {
            HStack(spacing: 10) {
                Image(systemName: RibbonGutterView.claudeSymbol).foregroundStyle(.secondary)
                Text(event.title).lineLimit(2)
                if event.path != nil {
                    Button("Show") { app.showClaudeEvent(event) }.buttonStyle(.hand).fontWeight(.semibold)
                }
                Button { app.workspace.claudeEvent = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hand).foregroundStyle(.tertiary).help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassPanel()
            .frame(maxWidth: 620)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
