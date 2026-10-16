import Foundation
import VetCore

/// Serves the bridge on a Unix socket that only this user can reach.
final class BridgeServer: @unchecked Sendable {
    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vet/bridge.sock").path
    }

    let router: BridgeRouter
    private let path: String
    private var fd: Int32 = -1

    init(router: BridgeRouter, path: String = BridgeServer.socketPath) {
        self.router = router
        self.path = path
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path) // a socket left by a crashed Vet
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103)) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        let listener = fd, router = router
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EBADF || errno == EINVAL { return }; continue }
                DispatchQueue.global().async { Self.serve(client, router: router) }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    private static func serve(_ client: Int32, router: BridgeRouter) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while data.count < 65_536 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if HTTPRequest.parse(data) != nil { break }
        }
        let (status, body) = HTTPRequest.parse(data).map { router.handle($0) } ?? (400, nil)
        let response = HTTPRequest.response(status: status, json: body)
        _ = response.withUnsafeBytes { write(client, $0.baseAddress, response.count) }
    }
}
