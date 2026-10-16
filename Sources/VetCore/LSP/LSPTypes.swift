import Foundation

/// The languages Vet navigates, each served by one language server.
public enum LSPLanguage: String, Sendable, Hashable, CaseIterable {
    case typescript // typescript-language-server, for TypeScript and JavaScript
    case python // pyright
    case kotlin // JetBrains kotlin-lsp

    public init?(fileExtension ext: String) {
        guard let language = Self.byExtension[ext.lowercased()]?.language else { return nil }
        self = language
    }

    /// The LSP `languageId` for a file extension (tsserver tells TSX from TS by it).
    public static func languageID(forExtension ext: String) -> String? {
        byExtension[ext.lowercased()]?.id
    }

    private static let byExtension: [String: (language: LSPLanguage, id: String)] = [
        "ts": (.typescript, "typescript"), "mts": (.typescript, "typescript"), "cts": (.typescript, "typescript"),
        "tsx": (.typescript, "typescriptreact"),
        "js": (.typescript, "javascript"), "mjs": (.typescript, "javascript"), "cjs": (.typescript, "javascript"),
        "jsx": (.typescript, "javascriptreact"),
        "py": (.python, "python"), "pyi": (.python, "python"),
        "kt": (.kotlin, "kotlin"), "kts": (.kotlin, "kotlin"),
    ]
}

public struct LSPPosition: Sendable, Hashable {
    public let line: Int
    public let character: Int // UTF-16 code units

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ json: JSONValue?) {
        guard let line = json?["line"]?.int, let character = json?["character"]?.int else { return nil }
        self.init(line: line, character: character)
    }

    public var json: JSONValue { ["line": .int(line), "character": .int(character)] }
}

public struct LSPRange: Sendable, Hashable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(_ json: JSONValue?) {
        guard let start = LSPPosition(json?["start"]), let end = LSPPosition(json?["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

public struct LSPLocation: Sendable, Hashable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    /// The result of definition, implementation and references requests, which may be
    /// `null`, one `Location`, `Location[]` or `LocationLink[]`. A link resolves to its
    /// target's selection range (the symbol's name), as editors jump to it. Duplicates are
    /// dropped, order kept.
    public static func list(from result: JSONValue) -> [LSPLocation] {
        let items: [JSONValue] = switch result {
        case .array(let a): a
        case .object: [result]
        default: []
        }
        var seen = Set<LSPLocation>()
        return items.compactMap { item -> LSPLocation? in
            if let uri = item["uri"]?.string, let range = LSPRange(item["range"]) {
                return LSPLocation(uri: uri, range: range)
            }
            if let uri = item["targetUri"]?.string,
               let range = LSPRange(item["targetSelectionRange"]) ?? LSPRange(item["targetRange"]) {
                return LSPLocation(uri: uri, range: range)
            }
            return nil
        }.filter { seen.insert($0).inserted }
    }
}

public enum LSPURI {
    /// `file://` URI for a local file or folder (no trailing slash, as VS Code sends it).
    public static func string(for url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return "file://" + (path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path)
    }

    /// The local file a `file://` URI names; nil for other schemes (`jar:`, `jrt:` and the like).
    public static func url(for uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: ";?#[]")
        return set
    }()
}

/// The JSON Vet sends and the replies it gives, independent of any process.
public enum LSPProtocol {
    /// `initialize` params: one workspace folder, the project root, and the client
    /// capabilities navigation needs (location links, configuration, progress).
    public static func initializeParams(processID: Int32, root: URL, initializationOptions: JSONValue?) -> JSONValue {
        let rootURI = LSPURI.string(for: root)
        var params: [String: JSONValue] = [
            "processId": .int(Int(processID)),
            "clientInfo": ["name": "Vet"],
            "locale": "en",
            "rootPath": .string(root.standardizedFileURL.path),
            "rootUri": .string(rootURI),
            "workspaceFolders": workspaceFolders(root),
            "trace": "off",
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": false, "willSave": false],
                    "definition": ["dynamicRegistration": false, "linkSupport": true],
                    "declaration": ["dynamicRegistration": false, "linkSupport": true],
                    "typeDefinition": ["dynamicRegistration": false, "linkSupport": true],
                    "implementation": ["dynamicRegistration": false, "linkSupport": true],
                    "references": ["dynamicRegistration": false],
                ],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "window": ["workDoneProgress": true],
            ],
        ]
        if let initializationOptions { params["initializationOptions"] = initializationOptions }
        return .object(params)
    }

    public static func workspaceFolders(_ root: URL) -> JSONValue {
        [["uri": .string(LSPURI.string(for: root)), "name": .string(root.lastPathComponent)]]
    }

    /// Params for definition, implementation and references.
    public static func positionParams(uri: String, line: Int, character: Int, includeDeclaration: Bool? = nil) -> JSONValue {
        var params: [String: JSONValue] = [
            "textDocument": ["uri": .string(uri)],
            "position": LSPPosition(line: line, character: character).json,
        ]
        if let includeDeclaration { params["context"] = ["includeDeclaration": .bool(includeDeclaration)] }
        return .object(params)
    }

    /// Replies to requests a server sends the client. Servers wait on some of these
    /// (pyright on `workspace/configuration`), so each gets an answer, even if it's "no".
    public static func reply(to method: String, params: JSONValue?, root: URL) -> Result<JSONValue, RPCError> {
        switch method {
        case "workspace/configuration":
            // One entry per requested item; null means "use your defaults".
            .success(.array((params?["items"]?.array ?? []).map { _ in .null }))
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
             "window/showMessageRequest":
            .success(.null)
        case "window/showDocument":
            .success(["success": false])
        case "workspace/workspaceFolders":
            .success(workspaceFolders(root))
        case "workspace/applyEdit":
            .success(["applied": false, "failureReason": "Vet doesn't apply server edits"])
        case "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh",
             "workspace/diagnostic/refresh", "workspace/inlineValue/refresh":
            .success(.null)
        default:
            .failure(RPCError(code: RPCError.methodNotFound, message: "Unhandled method \(method)"))
        }
    }
}
