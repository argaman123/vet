import SwiftUI

/// Find in Files: query, options, results grouped by file (engine wired in separately).
struct FindInFilesView: View {
    let app: AppDelegate
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField("Find in files", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
            EmptyToolState(title: "Find in Files", message: "Type to search the whole project.") { EmptyView() }
        }
    }
}
