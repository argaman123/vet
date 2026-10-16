import Foundation
import VetCore
import os

/// One language-server process for one project, spoken to over stdin/stdout with
/// Content-Length framed JSON-RPC. Its stderr goes to `~/Library/Logs/Vet/<name>.log`.
actor LanguageServer {
    struct Launch: Sendable {
        let name: String // log file and messages, e.g. "typescript"
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let initializationOptions: JSONValue?
        let startTimeout: Duration // spawn + initialize
        let requestTimeout: Duration
        /// The server answers "nothing" while it imports or indexes (kotlin-lsp), so requests
        /// wait for its reported work to finish first.
        let waitsForIndexing: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case notRunning(String)
        case timedOut(String)
        case exited(Int32)
        var description: String {
            switch self {
            case .notRunning(let why): "server not running: \(why)"
            case .timedOut(let method): "\(method) timed out"
            case .exited(let status): "server exited (\(status))"
            }
        }
    }

    nonisolated let root: URL
    nonisolated let launch: Launch

    private var process: Process?
    private var input: FileHandle?
    private var decoder = RPCFrameDecoder()
    private var pending = PendingRequests<Waiter>()
    private var startTask: Task<Void, Error>?
    private var exitStatus: Int32?
    private var documents: [String: (version: Int, text: String)] = [:] // by URI
    private var capabilities: JSONValue = .null
    private var progress: [String: String] = [:] // work-done token → title, while running
    private var progressBegun = 0 // work-done progress started so far
    private var initializedAt: ContinuousClock.Instant?

    private struct Waiter {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    private let log: Logger

    init(root: URL, launch: Launch) {
        self.root = root
        self.launch = launch
        self.log = Logger(subsystem: "Vet", category: "LSP.\(launch.name)")
    }

    /// False once the process has exited; the navigator starts a fresh one then.
    var isAlive: Bool { exitStatus == nil }

    /// Whether the server advertised `provider` (e.g. "implementationProvider") in `initialize`.
    func supports(_ provider: String) -> Bool {
        guard let value = capabilities[provider] else { return false }
        return value != .bool(false) && value != .null
    }

    // MARK: Lifecycle

    /// Spawns the process and runs the initialize handshake, once; later calls wait for the first.
    func start() async throws {
        if let exitStatus { throw Failure.exited(exitStatus) }
        if startTask == nil { startTask = Task { try await self.spawnAndInitialize() } }
        try await startTask!.value
    }

    private func spawnAndInitialize() async throws {
        let p = Process()
        p.executableURL = launch.executable
        p.arguments = launch.arguments
        p.environment = launch.environment
        p.currentDirectoryURL = root
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        let errorLog = Self.logFile(named: launch.name, header: "\(Date()) \(launch.executable.path) \(launch.arguments.joined(separator: " ")) in \(root.path)")
        p.standardError = errorLog
        defer { if errorLog !== FileHandle.nullDevice { try? errorLog.close() } } // the server keeps its own copy
        // A write to a server that died must fail, not raise SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (chunks, sink) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.exited(status) }
        }
        do {
            try p.run()
        } catch {
            exitStatus = -1
            throw Failure.notRunning("\(launch.executable.path): \(error.localizedDescription)")
        }
        process = p
        input = stdin.fileHandleForWriting
        // One consumer keeps the bytes in order.
        Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
        }

        let params = LSPProtocol.initializeParams(processID: ProcessInfo.processInfo.processIdentifier, root: root,
                                                  initializationOptions: launch.initializationOptions)
        do {
            let result = try await request("initialize", params, timeout: launch.startTimeout)
            capabilities = result["capabilities"] ?? .null
            try send(.notification(method: "initialized", params: [:]))
            initializedAt = .now
        } catch {
            // A server that can't initialize is useless; end it so the navigator can start afresh.
            log.error("\(self.launch.name, privacy: .public) failed to initialize: \(String(describing: error), privacy: .public)")
            if exitStatus == nil { exited(-1) }
            p.terminate()
            throw error
        }
        log.info("\(self.launch.name, privacy: .public) initialized for \(self.root.path, privacy: .public)")
    }

    /// Asks the server to shut down and exit, then makes sure it's gone.
    func stop() async {
        guard let process, exitStatus == nil else { return }
        if (try? await startTask?.value) != nil {
            _ = try? await request("shutdown", nil, timeout: .seconds(3))
            try? send(.notification(method: "exit", params: nil))
        }
        for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
    }

    private func exited(_ status: Int32) {
        exitStatus = status
        input = nil
        for waiter in pending.takeAll() {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: Failure.exited(status))
        }
        log.info("\(self.launch.name, privacy: .public) exited with status \(status)")
    }

    // MARK: Documents

    /// Makes the server see `text` as the file's contents (unsaved edits included):
    /// opens it the first time, then sends the whole text again when it changed.
    func sync(_ url: URL, text: String) throws {
        let uri = LSPURI.string(for: url)
        if let doc = documents[uri] {
            guard doc.text != text else { return }
            let version = doc.version + 1
            try send(.notification(method: "textDocument/didChange", params: [
                "textDocument": ["uri": .string(uri), "version": .int(version)],
                "contentChanges": [["text": .string(text)]],
            ]))
            documents[uri] = (version, text)
        } else {
            let languageID = LSPLanguage.languageID(forExtension: url.pathExtension) ?? "plaintext"
            try send(.notification(method: "textDocument/didOpen", params: [
                "textDocument": ["uri": .string(uri), "languageId": .string(languageID), "version": 1, "text": .string(text)],
            ]))
            documents[uri] = (1, text)
        }
    }

    /// Closes every document but `url`'s, so the server reads them from disk again: an open
    /// document's text wins over the file, and Claude may have changed the file since. One stays
    /// open so the server keeps its project loaded (tsserver drops a project with no open file).
    private func closeOthers(than url: URL) throws {
        let keep = LSPURI.string(for: url)
        for uri in documents.keys where uri != keep {
            try send(.notification(method: "textDocument/didClose", params: ["textDocument": ["uri": .string(uri)]]))
            documents[uri] = nil
        }
    }

    /// Syncs the document, then runs a definition/implementation/references request at a position.
    func locations(_ method: String, url: URL, text: String, line: Int, character: Int,
                   includeDeclaration: Bool? = nil) async throws -> [LSPLocation] {
        try await start()
        if let provider = Self.providers[method], !supports(provider) { return [] } // e.g. pyright has no implementation
        if launch.waitsForIndexing { try await waitForIndexing() }
        try sync(url, text: text)
        try closeOthers(than: url)
        let params = LSPProtocol.positionParams(uri: LSPURI.string(for: url), line: line, character: character,
                                                includeDeclaration: includeDeclaration)
        let begunBefore = progressBegun
        var found = LSPLocation.list(from: try await request(method, params))
        // Asked while a (re)import started: ask again once it's done.
        if found.isEmpty && launch.waitsForIndexing && (progressBegun != begunBefore || !progress.isEmpty) {
            try await waitForIndexing()
            found = LSPLocation.list(from: try await request(method, params))
        }
        return found
    }

    private static let providers = [
        "textDocument/definition": "definitionProvider",
        "textDocument/implementation": "implementationProvider",
        "textDocument/references": "referencesProvider",
    ]

    /// Waits, cancellably, while the server reports work in progress. A fresh server gets a
    /// moment to start its import first (kotlin-lsp begins right after `initialized`).
    private func waitForIndexing() async throws {
        let clock = ContinuousClock()
        if let initializedAt {
            while progressBegun == 0 && clock.now < initializedAt + .seconds(3) {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let deadline = clock.now + launch.requestTimeout
        while !progress.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: JSON-RPC

    /// Sends a request and waits for its response, failing after the timeout (and telling the
    /// server to cancel) or as soon as the calling task is cancelled.
    func request(_ method: String, _ params: JSONValue?, timeout: Duration? = nil) async throws -> JSONValue {
        if let exitStatus { throw Failure.exited(exitStatus) }
        let limit = timeout ?? launch.requestTimeout
        let id = pending.reserve()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation that came first has already run its handler and found nothing.
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    if !Task.isCancelled { await self?.abandon(id, with: Failure.timedOut(method)) }
                }
                pending.insert(Waiter(method: method, continuation: continuation, timeout: timer), for: id)
                do {
                    try send(.request(id: .int(id), method: method, params: params))
                } catch {
                    _ = pending.take(id)
                    timer.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.abandon(id, with: CancellationError()) }
        }
    }

    private func abandon(_ id: Int, with error: Error) {
        guard let waiter = pending.take(id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
        try? send(.notification(method: "$/cancelRequest", params: ["id": .int(id)]))
        log.info("\(self.launch.name, privacy: .public): \(waiter.method, privacy: .public) abandoned: \(String(describing: error), privacy: .public)")
    }

    private func send(_ message: RPCMessage) throws {
        guard let input else { throw Failure.notRunning("stdin closed") }
        try input.write(contentsOf: message.framed())
    }

    private func receive(_ chunk: Data) {
        let bodies: [Data]
        do {
            bodies = try decoder.append(chunk)
        } catch {
            log.error("\(self.launch.name, privacy: .public): \(String(describing: error), privacy: .public); stopping")
            process?.terminate()
            return
        }
        for body in bodies {
            guard let json = try? JSONValue.decode(body), let message = RPCMessage(json: json) else {
                log.error("\(self.launch.name, privacy: .public): unreadable message")
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: RPCMessage) {
        switch message {
        case .response(let id, let result):
            guard let waiter = pending.take(id) else { return } // late reply to an abandoned request
            waiter.timeout.cancel()
            switch result {
            case .success(let value): waiter.continuation.resume(returning: value)
            case .failure(let error): waiter.continuation.resume(throwing: error)
            }
        case .request(let id, let method, let params):
            try? send(.response(id: id, result: LSPProtocol.reply(to: method, params: params, root: root)))
        case .notification(let method, let params):
            switch method {
            case "$/progress":
                trackProgress(params)
            case "window/logMessage", "window/showMessage":
                // 1 error, 2 warning; the info and log chatter stays out of the log file.
                if let type = params?["type"]?.int, type <= 2, let text = params?["message"]?.string {
                    Self.append("[\(method)] \(text)", toLog: launch.name)
                }
            default:
                break // diagnostics, telemetry, $/typescriptVersion…
            }
        }
    }

    private func trackProgress(_ params: JSONValue?) {
        guard let token = params?["token"], let value = params?["value"] else { return }
        let key = token.string ?? token.int.map(String.init) ?? "?"
        switch value["kind"]?.string {
        case "begin":
            let title = value["title"]?.string ?? ""
            progress[key] = title
            progressBegun += 1
            log.info("\(self.launch.name, privacy: .public) progress: \(title, privacy: .public)")
        case "end":
            if let title = progress.removeValue(forKey: key) {
                log.info("\(self.launch.name, privacy: .public) done: \(title, privacy: .public)")
            }
        default:
            break
        }
    }

    /// Titles of the work the server reports in progress (e.g. kotlin-lsp's project import).
    var workInProgress: [String] { Array(progress.values) }

    // MARK: Logs

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vet", isDirectory: true)
    }

    /// The server's log, opened for appending with a header line; stderr is written straight into it.
    private static func logFile(named name: String, header: String) -> FileHandle {
        let url = logDirectory.appendingPathComponent("\(name).log")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        rotateIfLarge(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n==== \(header)\n".utf8))
        return handle
    }

    /// Logs are kept under about 5 MB: a bigger one becomes `<name>.old.log`, replacing the last.
    private static func rotateIfLarge(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 5_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    static func append(_ line: String, toLog name: String) {
        let url = logDirectory.appendingPathComponent("\(name).log")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        rotateIfLarge(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(line)\n".utf8))
    }
}
