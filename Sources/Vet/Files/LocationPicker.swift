import SwiftUI

/// Several places to go (references, implementations): pick one to open it in Files.
struct LocationPicker: View {
    let title: String
    let locations: [CodeLocation]
    let root: URL?
    let open: (CodeLocation) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) · \(locations.count)").font(.title3)
            List(rows, id: \.location) { row in
                Button { open(row.location) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.path):\(row.location.startLine + 1)").font(.callout)
                        Text(row.preview).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220, maxHeight: 420)
            HStack {
                Spacer()
                Button("Close", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private struct Row { let location: CodeLocation; let path: String; let preview: String }

    /// Each place with its path (relative to the project) and the line of code there.
    private var rows: [Row] {
        var cache: [URL: [Substring]] = [:]
        return locations.prefix(500).map { loc in
            let lines = cache[loc.url] ?? {
                let text = (try? String(contentsOf: loc.url, encoding: .utf8)) ?? ""
                let l = text.split(separator: "\n", omittingEmptySubsequences: false)
                cache[loc.url] = l
                return l
            }()
            let r = root?.standardizedFileURL.path ?? "", p = loc.url.standardizedFileURL.path
            let path = p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
            let preview = loc.startLine < lines.count ? lines[loc.startLine].trimmingCharacters(in: .whitespaces) : ""
            return Row(location: loc, path: path, preview: preview)
        }
    }
}
