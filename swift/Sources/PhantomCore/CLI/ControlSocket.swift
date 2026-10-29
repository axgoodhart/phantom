import Darwin
import Foundation

/// A newline-delimited JSON channel between the CLI and the running app.
///
/// The Python build coordinated through a PID file and a status file written
/// by a detached supervisor process. A socket removes the stale-state
/// problem: if nothing answers, nothing is running.
///
/// It also solves a permissions problem. Input events may only be posted by a
/// process trusted for Accessibility; a binary launched from Terminal is not
/// that process. Asking the app to play, rather than replaying in the CLI,
/// keeps the work inside the trusted bundle.
public enum ControlSocket {

    public static var socketURL: URL {
        WorkflowStore.applicationSupportDirectory.appendingPathComponent("control.sock")
    }

    static let maxMessageBytes = 1 << 20

    // MARK: - Server

    public final class Server {
        private var listenerFD: Int32 = -1
        private var thread: Thread?
        private var running = false
        private let handler: (Request) -> Response

        /// `handler` is invoked on a background thread.
        public init(handler: @escaping (Request) -> Response) {
            self.handler = handler
        }

        public func start() throws {
            let url = ControlSocket.socketURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // A socket left behind by a crash would block bind().
            try? FileManager.default.removeItem(at: url)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ControlError.socketFailed(errno) }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = url.path
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                throw ControlError.pathTooLong
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                path.withCString { source in
                    _ = strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                               source)
                }
            }

            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0 else {
                close(fd)
                throw ControlError.socketFailed(errno)
            }
            guard listen(fd, 8) == 0 else {
                close(fd)
                throw ControlError.socketFailed(errno)
            }
            // Only this user should be able to drive the app.
            chmod(path, 0o600)

            listenerFD = fd
            running = true
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.name = "com.alexgoodhart.Phantom.ControlSocket"
            self.thread = thread
            thread.start()
        }

        public func stop() {
            running = false
            if listenerFD >= 0 {
                close(listenerFD)
                listenerFD = -1
            }
            try? FileManager.default.removeItem(at: ControlSocket.socketURL)
        }

        private func acceptLoop() {
            while running {
                let client = accept(listenerFD, nil, nil)
                guard client >= 0 else {
                    if running, errno != EINTR { Thread.sleep(forTimeInterval: 0.1) }
                    continue
                }
                handle(client: client)
                close(client)
            }
        }

        private func handle(client: Int32) {
            guard let line = ControlSocket.readLine(from: client) else { return }
            let response: Response
            if let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) {
                response = handler(request)
            } else {
                response = Response(status: "error", message: "Malformed request")
            }
            ControlSocket.write(response, to: client)
        }
    }

    // MARK: - Client

    /// Sends one request and waits for the reply. Returns nil when nothing
    /// is listening.
    public static func send(_ request: Request, timeout: TimeInterval = 10) -> Response? {
        let path = socketURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                           source)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }

        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        var line = payload
        line.append(0x0A)
        let sent = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(fd, base, buffer.count)
        }
        guard sent > 0 else { return nil }

        guard let reply = readLine(from: fd) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: Data(reply.utf8))
    }

    // MARK: - Framing

    private static func readLine(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maxMessageBytes {
            let count = read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }

    private static func write(_ response: Response, to fd: Int32) {
        guard var payload = try? JSONEncoder().encode(response) else { return }
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(fd, base, buffer.count)
        }
    }

    // MARK: - Messages

    public struct Request: Codable {
        public var command: String
        public var workflow: String?
        public var speed: Double?
        public var loop: Int?
        public var loopDelay: Double?
        public var matchResolution: Bool?
        public var matchWindows: Bool?

        public init(command: String, workflow: String? = nil, speed: Double? = nil,
                    loop: Int? = nil, loopDelay: Double? = nil,
                    matchResolution: Bool? = nil, matchWindows: Bool? = nil) {
            self.command = command
            self.workflow = workflow
            self.speed = speed
            self.loop = loop
            self.loopDelay = loopDelay
            self.matchResolution = matchResolution
            self.matchWindows = matchWindows
        }
    }

    public struct Response: Codable {
        public var status: String
        public var message: String?
        public var workflow: String?
        public var progress: Double?
        public var current: Int?
        public var total: Int?
        public var iteration: Int?
        /// The app's own permission state, which is the one that matters for
        /// recording and playback.
        public var accessibility: Bool?
        public var screenRecording: Bool?

        public init(status: String, message: String? = nil, workflow: String? = nil,
                    progress: Double? = nil, current: Int? = nil, total: Int? = nil,
                    iteration: Int? = nil, accessibility: Bool? = nil,
                    screenRecording: Bool? = nil) {
            self.status = status
            self.message = message
            self.workflow = workflow
            self.progress = progress
            self.current = current
            self.total = total
            self.iteration = iteration
            self.accessibility = accessibility
            self.screenRecording = screenRecording
        }
    }

    public enum ControlError: LocalizedError {
        case socketFailed(Int32)
        case pathTooLong

        public var errorDescription: String? {
            switch self {
            case .socketFailed(let code):
                return "Control socket error (\(code): \(String(cString: strerror(code))))"
            case .pathTooLong:
                return "Control socket path is too long"
            }
        }
    }
}
