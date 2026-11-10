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
    /// Changes when `output` is replaced rather than appended to (a new run, Clear, trimming),
    /// so the panel knows when it can just append.
    private(set) var outputEpoch = 0
    var outputVisible = false
    /// Called once per run with the first local URL the app prints (opens it in the Browser tab).
    var onLocalURL: ((URL) -> Void)?
    /// The address the running app printed (its first local URL), while it runs.
    private(set) var localURL: URL?

    private var root: URL?
    private var pid: pid_t = 0
    private var stopping = false
    private var exitSource: DispatchSourceProcess?
    private var reader: FileHandle?
    private var sawURL = false
    /// Bumped by every start and by stopping or switching projects while a start is still
    /// loading the environment, so a stale start never launches.
    private var launchGeneration = 0
    private var leaderStatus: Int32 = 0
    private static let maxOutput = 1_000_000

    var selected: RunConfig? { configs.first { $0.id == selectedID } ?? configs.first }

    func open(_ folder: URL?) {
        if isRunning { stop() }
        root = nil // so clearing the selection below doesn't save over the new project's configs
        configs = []
        selectedID = nil
        output = ""
        crashed = false
        localURL = nil
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
        localURL = nil
        stopping = false
        isRunning = true // Stop shows right away; `pid` stays 0 until the process exists
        output = "$ \(config.command)\n"
        outputEpoch += 1
        outputVersion += 1
        launchGeneration += 1
        let generation = launchGeneration
        let cwd = config.cwd.hasPrefix("/") ? config.cwd : root.appendingPathComponent(config.cwd).path
        Task {
            var env = await ShellEnvironment.load()
            guard generation == launchGeneration else { return } // stopped or switched projects meanwhile
            for (k, v) in config.env ?? [:] { env[k] = v }
            env["FORCE_COLOR"] = "0"
            // Python buffers its output when it isn't a terminal; the "Serving on http://…" line
            // (and every print) should show as it happens.
            env["PYTHONUNBUFFERED"] = env["PYTHONUNBUFFERED"] ?? "1"
            launch(command: config.command, cwd: cwd, env: env)
        }
    }

    /// Stops the whole process group (so `npm run start` takes its dev server with it).
    func stop() {
        guard isRunning else { return }
        guard pid > 0 else { // still starting
            launchGeneration += 1
            isRunning = false
            append("\n[stopped]\n")
            return
        }
        stopping = true
        let group = pid
        kill(-group, SIGTERM)
        // Whatever ignores SIGTERM, including children that outlive the shell, gets SIGKILL.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }

    /// Stops the run and waits (at most about 4 s) until all of its processes are gone.
    func stopAndWait() async {
        let group = pid
        stop()
        guard group > 0 else { return }
        for tick in 0..<40 {
            if kill(-group, 0) != 0 { return }
            if tick == 30 { kill(-group, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func clearOutput() {
        output = ""
        outputEpoch += 1
        outputVersion += 1
    }

    private func launch(command: String, cwd: String, env: [String: String]) {
        let pipe = Pipe()
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Its own process group, so Stop reaches its children; only stdin/out/err inherited; signals
        // as a fresh process expects them (Vet ignores SIGPIPE, which a dev server must not).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
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
            isRunning = false
            return
        }
        pid = child
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
        leaderStatus = status
        waitForGroup()
    }

    /// The shell has exited; the run is over once every process it started has too (a dev
    /// server can outlive its shell), so Stop stays available until then.
    private func waitForGroup() {
        let group = pid
        if group > 0, kill(-group, 0) == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.pid == group else { return }
                self.waitForGroup()
            }
            return
        }
        isRunning = false
        pid = 0
        let status = leaderStatus
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if !stopping && code != 0 { crashed = true }
        append(stopping ? "\n[stopped]\n" : "\n[exited with code \(code)]\n")
    }

    private func append(_ text: String) {
        output += Self.stripANSI(text)
        if output.utf8.count > Self.maxOutput {
            // Keep the newest half, starting at a line.
            let utf8 = output.utf8
            let cut = utf8.index(utf8.startIndex, offsetBy: utf8.count - Self.maxOutput / 2)
            let start = utf8[cut...].firstIndex(of: 10).map { utf8.index(after: $0) } ?? utf8.endIndex
            output = String(output[start...])
            outputEpoch += 1
        }
        outputVersion += 1
        if !sawURL, let url = Self.localURL(in: text) {
            sawURL = true
            localURL = url
            onLocalURL?(url)
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func localURL(in text: String) -> URL? {
        let clean = stripANSI(text)
        guard let r = clean.range(of: "https?://(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)(:[0-9]+)?(/[^\\s]*)?", options: .regularExpression) else { return nil }
        // "(http://127.0.0.1:8765/) ..." — closing punctuation belongs to the sentence, not the URL.
        var found = String(clean[r])
        while let last = found.last, ")]}>.,;:'\"".contains(last), !found.hasSuffix("//") { found.removeLast() }
        return URL(string: found.replacingOccurrences(of: "0.0.0.0", with: "localhost"))
    }

    // MARK: Storage

    private struct Stored: Codable {
        var configs: [RunConfig]
        var selected: String?
    }

    /// In the project's .vet folder (which git ignores).
    private func storeURL(_ folder: URL) -> URL { ProjectFolder.url(folder, "run.json") }

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
