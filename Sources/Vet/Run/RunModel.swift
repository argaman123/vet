import AppKit
import CryptoKit
import Observation

struct RunConfig: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var command: String
    /// Relative to the project folder, or absolute.
    var cwd: String = "."
    var env: [String: String]? = nil
}

/// Run/Stop for the open project: named commands, output in the bottom panel, a red dot on a crash.
@MainActor @Observable
final class RunModel {
    private(set) var configs: [RunConfig] = []
    var selectedID: String? { didSet { save() } }
    private(set) var isRunning = false
    /// The last run ended on its own with a failure exit code.
    private(set) var crashed = false
    private(set) var output = ""
    private(set) var outputVersion = 0
    var outputVisible = false
    /// Called once per run with the first local URL the app prints (opens it in the Browser tab).
    var onLocalURL: ((URL) -> Void)?

    private var root: URL?
    private var pid: pid_t = 0
    private var stopping = false
    private var exitSource: DispatchSourceProcess?
    private var reader: FileHandle?
    private var sawURL = false
    private static let maxOutput = 1_000_000

    var selected: RunConfig? { configs.first { $0.id == selectedID } ?? configs.first }

    func open(_ folder: URL?) {
        if isRunning { stop() }
        root = nil // so clearing the selection below doesn't save over the new project's configs
        configs = []
        selectedID = nil
        output = ""
        crashed = false
        guard let folder else { return }
        root = folder
        if let data = try? Data(contentsOf: storeURL(folder)), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            configs = stored.configs
            selectedID = stored.selected
        } else {
            configs = Self.importFromVSCode(folder) // your Working Tree run configurations
            selectedID = configs.first?.id
            save()
        }
    }

    func setConfigs(_ list: [RunConfig]) {
        configs = list.filter { !$0.name.isEmpty || !$0.command.isEmpty }
        if !configs.contains(where: { $0.id == selectedID }) { selectedID = configs.first?.id }
        save()
    }

    // MARK: Run and stop

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning, let root, let config = selected else { return }
        crashed = false
        sawURL = false
        stopping = false
        output = "$ \(config.command)\n"
        outputVersion += 1
        let cwd = config.cwd.hasPrefix("/") ? config.cwd : root.appendingPathComponent(config.cwd).path
        Task {
            var env = await ShellEnvironment.load()
            for (k, v) in config.env ?? [:] { env[k] = v }
            env["FORCE_COLOR"] = "0"
            launch(command: config.command, cwd: cwd, env: env)
        }
    }

    /// Stops the whole process group (so `npm run start` takes its dev server with it).
    func stop() {
        guard isRunning, pid > 0 else { return }
        stopping = true
        let group = pid
        kill(-group, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning, self.pid == group else { return }
            kill(-group, SIGKILL)
        }
    }

    func clearOutput() {
        output = ""
        outputVersion += 1
    }

    private func launch(command: String, cwd: String, env: [String: String]) {
        let pipe = Pipe()
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0) // its own process group, so Stop reaches its children
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        let argv = ["/bin/zsh", "-c", command].map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/zsh", &actions, &attr, argv, envp)
        try? pipe.fileHandleForWriting.close()
        guard rc == 0 else {
            append("Couldn't start: \(String(cString: strerror(rc)))\n")
            crashed = true
            return
        }
        pid = child
        isRunning = true
        reader = pipe.fileHandleForReading
        reader?.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            MainActor.assumeIsolated { self?.exited(status: status) }
        }
        source.resume()
        exitSource = source
    }

    private func exited(status: Int32) {
        exitSource?.cancel()
        exitSource = nil
        isRunning = false
        pid = 0
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if !stopping && code != 0 { crashed = true }
        append(stopping ? "\n[stopped]\n" : "\n[exited with code \(code)]\n")
    }

    private func append(_ text: String) {
        output += Self.stripANSI(text)
        if output.utf8.count > Self.maxOutput { output = String(output.suffix(Self.maxOutput / 2)) }
        outputVersion += 1
        if !sawURL, let url = Self.localURL(in: text) {
            sawURL = true
            onLocalURL?(url)
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func localURL(in text: String) -> URL? {
        let clean = stripANSI(text)
        guard let r = clean.range(of: "https?://(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)(:[0-9]+)?(/[^\\s]*)?", options: .regularExpression) else { return nil }
        return URL(string: clean[r].replacingOccurrences(of: "0.0.0.0", with: "localhost"))
    }

    // MARK: Storage

    private struct Stored: Codable {
        var configs: [RunConfig]
        var selected: String?
    }

    private func storeURL(_ folder: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vet/run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(key).json")
    }

    private func save() {
        guard let root, let data = try? JSONEncoder().encode(Stored(configs: configs, selected: selectedID)) else { return }
        try? data.write(to: storeURL(root), options: .atomic)
    }

    /// Reads `changeReview.runConfigurations` from .vscode/settings.json (JSON with comments).
    static func importFromVSCode(_ folder: URL) -> [RunConfig] {
        guard let raw = try? String(contentsOf: folder.appendingPathComponent(".vscode/settings.json"), encoding: .utf8) else { return [] }
        let noComments = raw.replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: ",(\\s*[}\\]])", with: "$1", options: .regularExpression)
        guard let json = try? JSONSerialization.jsonObject(with: Data(noComments.utf8)) as? [String: Any],
              let list = json["changeReview.runConfigurations"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let command = d["command"] as? String else { return nil }
            return RunConfig(id: (d["id"] as? String) ?? UUID().uuidString, name: (d["name"] as? String) ?? command,
                             command: command, cwd: (d["cwd"] as? String) ?? ".", env: d["env"] as? [String: String])
        }
    }
}
