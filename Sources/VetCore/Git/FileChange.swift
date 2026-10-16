/// How a file differs from HEAD (the review baseline).
public enum ChangeKind: Sendable, Hashable {
    case modified, added, deleted, renamed, untracked, conflicted
}

/// How much of a file's change is in the git index. Staged means reviewed.
public enum StageState: Sendable, Hashable {
    /// The index equals HEAD.
    case unstaged
    /// The index equals the working file.
    case staged
    /// Anything in between.
    case partial
}

public struct FileChange: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// Repo-relative path in the working tree.
    public let path: String
    /// Original path for renames.
    public let origPath: String?
    public let kind: ChangeKind
    public let stage: StageState
    /// File mode in the index (e.g. "100644"), or the working-tree mode when not in the index.
    public let modeIndex: String
    public let modeWork: String

    public init(path: String, origPath: String? = nil, kind: ChangeKind, stage: StageState,
                modeIndex: String = "100644", modeWork: String = "100644") {
        self.path = path
        self.origPath = origPath
        self.kind = kind
        self.stage = stage
        self.modeIndex = modeIndex
        self.modeWork = modeWork
    }
}
