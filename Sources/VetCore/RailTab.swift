/// The tabs on Vet's left rail, top to bottom.
public enum RailTab: String, CaseIterable, Sendable, Identifiable {
    case claude, review, files, browser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .review: "Review"
        case .files: "Files"
        case .browser: "Browser"
        }
    }

    /// SF Symbol shown on the rail.
    public var symbolName: String {
        switch self {
        case .claude: "bubble.left.and.text.bubble.right"
        case .review: "arrow.left.arrow.right.square"
        case .files: "folder"
        case .browser: "globe"
        }
    }
}
