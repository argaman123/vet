/// The tabs on Vet's left rail, top to bottom.
public enum RailTab: String, CaseIterable, Sendable, Identifiable {
    case review, files, browser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .review: "Review"
        case .files: "Files"
        case .browser: "Browser"
        }
    }

    /// SF Symbol shown on the rail.
    public var symbolName: String {
        switch self {
        case .review: "arrow.left.arrow.right.square"
        case .files: "folder"
        case .browser: "globe"
        }
    }
}
