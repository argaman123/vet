import Foundation
import os

/// The user's login-shell environment, captured once. A GUI app launched from the Finder
/// inherits launchd's bare environment, so tools set up in `.zshrc` (nvm's `node`, `JAVA_HOME`)
/// would be missing. Like VS Code's "resolve shell env", this runs an interactive login zsh
/// once and reads its environment, falling back to Vet's own environment when that fails.
enum ShellEnvironment {
    private static let resolved = Task.detached(priority: .userInitiated) { await resolve() }

    /// The captured environment; the first call waits for the shell (bounded by a timeout).
    static func load() async -> [String: String] {
        await resolved.value
    }

    private static let timeout: TimeInterval = 10
    private static let log = Logger(subsystem: "Vet", category: "ShellEnvironment")

    private static func resolve() async -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        let started = Date()
        let mark = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let output = await runShell(mark: mark) else {
            log.error("shell environment: zsh didn't answer; using Vet's own environment")
            return fallback
        }
        // rc files may print before or after our command; only what's between the marks counts.
        guard let open = output.range(of: Data(mark.utf8)),
              let close = output.range(of: Data(mark.utf8), in: open.upperBound..<output.endIndex) else {
            log.error("shell environment: no marked output from zsh; using Vet's own environment")
            return fallback
        }
        var env: [String: String] = [:]
        for entry in output[open.upperBound..<close.lowerBound].split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        for key in ["VET_RESOLVING_ENVIRONMENT", "SHLVL", "_", "PWD", "OLDPWD"] { env.removeValue(forKey: key) }
        guard env["PATH"] != nil else {
            log.error("shell environment: zsh reported no PATH; using Vet's own environment")
            return fallback
        }
        log.info("shell environment: \(env.count) variables in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return env
    }

    /// Runs `zsh -ilc` printing the environment between two marks. Returns everything it wrote,
    /// or nil when it fails or outlives the timeout. Returns as soon as the closing mark shows up,
    /// so a background helper an rc file leaves holding stdout can't stall it.
    private static func runShell(mark: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ilc", "command printf '%s' \(mark); command env -0; command printf '%s' \(mark)"]
            var env = ProcessInfo.processInfo.environment
            env["VET_RESOLVING_ENVIRONMENT"] = "1" // lets an rc file skip slow or interactive setup
            p.environment = env
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice

            let state = OSAllocatedUnfairLock(initialState: (buffer: Data(), done: false))
            @Sendable func finish(_ result: Data?) {
                let first = state.withLock { s -> Bool in
                    if s.done { return false }
                    s.done = true
                    return true
                }
                guard first else { return }
                out.fileHandleForReading.readabilityHandler = nil
                if p.isRunning { p.terminate() }
                continuation.resume(returning: result)
            }
            let markData = Data(mark.utf8)
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { // EOF
                    finish(state.withLock { $0.buffer })
                    return
                }
                let complete = state.withLock { s -> Data? in
                    s.buffer.append(chunk)
                    guard let first = s.buffer.range(of: markData),
                          s.buffer.range(of: markData, in: first.upperBound..<s.buffer.endIndex) != nil else { return nil }
                    return s.buffer
                }
                if let complete { finish(complete) }
            }
            do {
                try p.run()
            } catch {
                finish(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
