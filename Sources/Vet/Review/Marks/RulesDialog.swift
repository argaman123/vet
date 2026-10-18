import SwiftUI

/// "Unimportant rules" (as in Working Tree): every mark and glob rule as an editable line.
struct RulesDialog: View {
    let model: ReviewModel
    @Binding var isPresented: Bool
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unimportant rules").font(.title3)
            Text(verbatim: "Matching files stage themselves. *.html matches at any depth; src/generated/** a folder and everything in it; **/generated/** such folders anywhere; ? one character. Case-sensitive.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(lines.indices, id: \.self) { i in
                        HStack {
                            TextField("pattern or path", text: $lines[i]).textFieldStyle(.roundedBorder)
                            Button { lines.remove(at: i) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove")
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            HStack {
                Button { lines.append("") } label: { Label("Add rule", systemImage: "plus") }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    // Exact paths without wildcards stay marks; anything with * or ? is a rule.
                    let clean = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.setMarkRules(marks: clean.filter { !$0.contains("*") && !$0.contains("?") },
                                       rules: clean.filter { $0.contains("*") || $0.contains("?") })
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { lines = model.markRules.marks + model.markRules.rules }
    }
}
