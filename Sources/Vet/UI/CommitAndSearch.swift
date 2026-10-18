import SwiftUI
import VetCore

// MARK: Commit: a popover from the toolbar's prominent Commit button

struct CommitPopover: View {
    let app: AppDelegate
    @State private var message = ""
    @State private var amend = false
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        let review = app.workspace.review
        let files = review.changes.filter { review.stage(of: $0) != .unstaged }
        VStack(alignment: .leading, spacing: 10) {
            Text(amend ? "Amend the last commit" : "Commit \(files.count) reviewed file\(files.count == 1 ? "" : "s")").font(.headline)
            TextEditor(text: $message)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Message").foregroundStyle(.tertiary).padding(.leading, 10).padding(.top, 5).allowsHitTesting(false)
                    }
                }
            Toggle("Amend last commit", isOn: $amend)
                .onChange(of: amend) { _, on in
                    if on, message.isEmpty { Task { message = await review.lastCommitMessage() ?? "" } }
                }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Commit and Push…") { commit(push: true) }
                    .disabled(working || (message.isEmpty && !amend))
                Button("Commit") { commit(push: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (message.isEmpty && !amend))
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func commit(push: Bool) {
        working = true
        Task {
            let ok = await app.workspace.review.commit(message: message, amend: amend, push: push)
            working = false
            if ok { message = ""; amend = false; app.ui.showCommit = false }
        }
    }
}

// MARK: Search Everywhere suggestions (filled in by the search engine)

struct SearchEverywhereSuggestions: View {
    let app: AppDelegate
    var body: some View {
        let results = app.workspace.searchResults
        ForEach(results.sections, id: \.title) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    Label {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(item.detail).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: item.symbol) }
                    .searchCompletion(item.id)
                }
            }
        }
    }
}

/// What Search Everywhere shows for the current query, grouped (Files, Classes & Symbols, Actions, Text).
struct SearchResults {
    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }
    struct Group { let title: String; let items: [Item] }
    var sections: [Group] = []
}

// MARK: Find in Files (filled in by the search engine)

struct FindTool: View {
    let app: AppDelegate
    var body: some View {
        FindInFilesView(app: app)
    }
}
