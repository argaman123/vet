import CryptoKit
import Foundation
import VetCore
import os

/// A place in a file, as a language server reports it: 0-based lines, characters in UTF-16 units.
struct CodeLocation: Sendable, Hashable {
    let url: URL
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
}

extension CodeLocation {
    /// Nil for locations outside the file system (`jar:`/`jrt:` library sources).
    init?(_ location: LSPLocation) {
        guard let url = LSPURI.url(for: location.uri) else { return nil }
        self.init(url: url, startLine: location.range.start.line, startCharacter: location.range.start.character,
                  endLine: location.range.end.line, endCharacter: location.range.end.character)
    }
}

/// Go to definition, go to implementation and find references for one project, and the
/// reading aids (hover, semantic tokens, inlay hints, code lenses, symbols, gutter marks; see
/// CodeReading.swift), through language servers started on first use (one per language).
/// `text` is the editor's current text for `url`, so unsaved edits are taken into account.
/// Every failure (no server installed, a timeout, a crash) comes back as no results;
/// cancelling the calling task cancels the request.
@MainActor final class CodeNavigator {
    let root: URL
    private var servers: [LSPLanguage: Task<LanguageServer?, Never>] = [:]
    private var restarts: [LSPLanguage: Int] = [:]
    private static let maxRestarts = 3
    /// Hover, tokens, hints, lenses, symbols and gutter marks already asked for (CodeReading.swift).
    let reading = ReadingCaches()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func isSupported(_ url: URL) -> Bool {
        LSPLanguage(fileExtension: url.pathExtension) != nil
    }

    func definition(of url: URL, text: String, line: Int, character: Int) async -> [CodeLocation] {
        await query("textDocument/definition", url, text, line, character)
    }

    func implementation(of url: URL, text: String, line: Int, character: Int) async -> [CodeLocation] {
        await query("textDocument/implementation", url, text, line, character)
    }

    func references(of url: URL, text: String, line: Int, character: Int) async -> [CodeLocation] {
        await query("textDocument/references", url, text, line, character, includeDeclaration: true)
    }

    /// Stops every server this navigator started (in the background).
    func shutdown() {
        let running = Array(servers.values)
        servers = [:]
        reading.removeAll()
        Task.detached {
            for task in running { await task.value?.stop() }
        }
    }

    /// Stops every server and waits for them (used when Vet quits).
    func shutdownAndWait() async {
        let running = Array(servers.values)
        servers = [:]
        await withTaskGroup(of: Void.self) { group in
            for task in running { group.addTask { await task.value?.stop() } }
        }
    }

    // MARK: Private

    private static let log = Logger(subsystem: "Vet", category: "CodeNavigator")

    private func query(_ method: String, _ url: URL, _ text: String, _ line: Int, _ character: Int,
                       includeDeclaration: Bool? = nil) async -> [CodeLocation] {
        guard let language = LSPLanguage(fileExtension: url.pathExtension),
              let server = await server(for: language) else { return [] }
        do {
            let found = try await server.locations(method, url: url, text: text, line: line, character: character,
                                                   includeDeclaration: includeDeclaration)
            return found.compactMap(CodeLocation.init)
        } catch is CancellationError {
            return []
        } catch {
            Self.log.error("\(method, privacy: .public) in \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The languages whose server was started and is still alive (none is started here).
    func runningLanguages() async -> [LSPLanguage] {
        var running: [LSPLanguage] = []
        for language in LSPLanguage.allCases {
            if let task = servers[language], let server = await task.value, await server.isAlive {
                running.append(language)
            }
        }
        return running
    }

    /// The running server for `language`, started on first use and restarted (a few times)
    /// after it exits. Nil when it isn't installed; that's checked again on the next call, so
    /// installing servers while Vet runs works.
    func server(for language: LSPLanguage) async -> LanguageServer? {
        if let task = servers[language] {
            guard let server = await task.value else { return nil } // a launch in flight found nothing
            if await server.isAlive { return server }
            guard servers[language] == task else { return await self.server(for: language) } // replaced meanwhile
            servers[language] = nil
            restarts[language, default: 0] += 1
            if restarts[language] == Self.maxRestarts + 1 {
                Self.log.error("\(language.rawValue, privacy: .public) server keeps exiting; not restarting it again")
            }
        }
        guard restarts[language, default: 0] <= Self.maxRestarts else { return nil }
        let root = self.root
        let task = Task<LanguageServer?, Never> {
            guard let launch = await LanguageServerCatalog.launch(for: language, root: root) else { return nil }
            return LanguageServer(root: root, launch: launch)
        }
        servers[language] = task
        let server = await task.value
        if server == nil && servers[language] == task { servers[language] = nil }
        return server
    }
}

/// Where each language server is installed (by scripts/install-language-servers.sh) and how
/// it's launched.
enum LanguageServerCatalog {
    static var serversDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/servers", isDirectory: true)
    }

    static func launch(for language: LSPLanguage, root: URL) async -> LanguageServer.Launch? {
        let env = await ShellEnvironment.load()
        let node = serversDirectory.appendingPathComponent("node/node_modules", isDirectory: true)
        switch language {
        case .typescript:
            let script = node.appendingPathComponent("typescript-language-server/lib/cli.mjs")
            guard let nodeBinary = nodeExecutable(env, for: language, script: script) else { return nil }
            let options: JSONValue = [
                "hostInfo": "Vet",
                "disableAutomaticTypingAcquisition": true, // no npm installs of @types behind the user's back
                "tsserver": [
                    // The project's own TypeScript is used when it has one; this one otherwise.
                    "fallbackPath": .string(node.appendingPathComponent("typescript/lib/tsserver.js").path),
                    // Only used if logging is turned on; the default is the project folder.
                    "logDirectory": .string(LanguageServer.logDirectory.appendingPathComponent("tsserver").path),
                    // One semantic tsserver. With the extra syntax server, requests made while the
                    // project loads get answered from the open file alone (an import line instead
                    // of the class); waiting a few seconds for the real answer is better for ⌘-click.
                    "useSyntaxServer": "never",
                ],
                // Inlay hints are tsserver preferences, all off by default: parameter names for
                // literal arguments, and the types of variables, return values and properties.
                "preferences": [
                    "includeInlayParameterNameHints": "literals",
                    "includeInlayParameterNameHintsWhenArgumentMatchesName": false,
                    "includeInlayVariableTypeHints": true,
                    "includeInlayVariableTypeHintsWhenTypeMatchesName": false,
                    "includeInlayFunctionLikeReturnTypeHints": true,
                    "includeInlayPropertyDeclarationTypeHints": true,
                ],
            ]
            // Code lenses are workspace settings, read only from workspace/didChangeConfiguration.
            // References on every function, as WebStorm counts usages of each declaration.
            let lenses: JSONValue = [
                "implementationsCodeLens": ["enabled": true],
                "referencesCodeLens": ["enabled": true, "showOnAllFunctions": true],
            ]
            return .init(name: "typescript", executable: nodeBinary, arguments: [script.path, "--stdio"],
                         environment: env, initializationOptions: options,
                         startTimeout: .seconds(60), requestTimeout: .seconds(60), waitsForIndexing: false,
                         settings: ["typescript": lenses, "javascript": lenses])
        case .python:
            let script = node.appendingPathComponent("pyright/langserver.index.js")
            guard let nodeBinary = nodeExecutable(env, for: language, script: script) else { return nil }
            return .init(name: "pyright", executable: nodeBinary, arguments: [script.path, "--stdio"],
                         environment: env, initializationOptions: nil,
                         startTimeout: .seconds(60), requestTimeout: .seconds(60), waitsForIndexing: false)
        case .kotlin:
            let home = serversDirectory.appendingPathComponent("kotlin-lsp/current", isDirectory: true)
            let launcher = home.appendingPathComponent("bin/intellij-server")
            guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
                reportMissing(language, "kotlin-lsp isn't installed at \(launcher.path)")
                return nil
            }
            // The launcher runs the Java runtime in its own jbr/ folder (bundled, or WebStorm's
            // linked there by the install script); kotlin-lsp needs Java 25.
            guard FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("jbr/Contents/Home/bin/java").path) else {
                reportMissing(language, "kotlin-lsp has no Java runtime in \(home.appendingPathComponent("jbr").path)")
                return nil
            }
            // Indexes per project, so two projects' servers don't fight over one cache. The shell
            // environment's JAVA_HOME is what kotlin-lsp's Gradle import runs Gradle with.
            // Inlay hints are off unless the client's "jetbrains.kotlin" configuration names them:
            // IntelliJ's option ids, flattened (kotlin-lsp joins nested keys with dots).
            let hints: JSONValue = [
                "hints.parameters": true, "hints.parameters.compiled": true,
                "hints.type.variable": true, "hints.type.property": true, "hints.type.function.return": true,
                "hints.lambda.return": true, "hints.lambda.receivers.parameters": true,
                "hints.value.ranges": true,
            ]
            return .init(name: "kotlin-lsp", executable: launcher,
                         arguments: ["--stdio", "--system-path=\(kotlinCache(for: root).path)"],
                         environment: env, initializationOptions: nil,
                         startTimeout: .seconds(120), requestTimeout: .seconds(180), waitsForIndexing: true,
                         settings: ["jetbrains": ["kotlin": hints]])
        }
    }

    private static func kotlinCache(for root: URL) -> URL {
        let hash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/kotlin-lsp/\(root.lastPathComponent)-\(hash)", isDirectory: true)
    }

    /// `node` from the login shell's PATH (nvm), else the newest nvm install, else Homebrew's.
    private static func nodeExecutable(_ env: [String: String], for language: LSPLanguage, script: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: script.path) else {
            reportMissing(language, "no server at \(script.path)")
            return nil
        }
        let fm = FileManager.default
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("node")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        for version in versions.reversed() {
            let candidate = nvm.appendingPathComponent("\(version)/bin/node")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        reportMissing(language, "node wasn't found (looked in the login shell's PATH, ~/.nvm and Homebrew)")
        return nil
    }

    private static let reported = OSAllocatedUnfairLock(initialState: Set<LSPLanguage>())

    /// One clear line per language and launch of Vet, in the unified log and in
    /// ~/Library/Logs/Vet/navigation.log.
    private static func reportMissing(_ language: LSPLanguage, _ why: String) {
        guard reported.withLock({ $0.insert(language).inserted }) else { return }
        let line = "Code navigation for \(language.rawValue) is off: \(why). Run scripts/install-language-servers.sh."
        Logger(subsystem: "Vet", category: "CodeNavigator").error("\(line, privacy: .public)")
        LanguageServer.append("\(Date()) \(line)", toLog: "navigation")
    }
}
