import Foundation
import Network

/// Talks to the Tuya (Wipro) smart plug over the local network, never the cloud.
/// One short TCP connection per command: send a frame, read one reply, close.
/// The plug drops the first connection after it has sat idle for a while (its
/// Wi-Fi dozes), then answers normally, so a dropped connection is retried.
///
/// macOS asks once for Local Network access ("Awake would like to find devices
/// on your local network"); until it is allowed, connections fail.
struct SmartPlug: Sendable {
    let credentials: PlugCredentials
    var port: UInt16 = 6668
    var timeout: TimeInterval = 5
    var attempts = 3
    var retryDelay: Duration = .seconds(1)

    enum PlugError: LocalizedError {
        case timedOut
        case connectionFailed(String)
        /// The plug reset or closed the connection before replying.
        case dropped
        case unexpectedReply

        var errorDescription: String? {
            switch self {
            case .timedOut: "The plug didn't answer."
            case .connectionFailed(let reason): "Couldn't reach the plug (\(reason))."
            case .dropped: "The plug kept closing the connection."
            case .unexpectedReply: "The plug sent an unexpected reply."
            }
        }
    }

    /// Switches the plug on or off. Returns once the plug acknowledges.
    func set(on: Bool) async throws {
        let frame = TuyaProtocol.controlFrame(
            deviceID: credentials.deviceID, key: credentials.key, switchDP: credentials.switchDP,
            on: on, time: Int(Date().timeIntervalSince1970), sequence: 1
        )
        _ = try await exchange(frame)
    }

    /// Reads whether the plug is on.
    func isOn() async throws -> Bool {
        let frame = TuyaProtocol.queryFrame(
            deviceID: credentials.deviceID, key: credentials.key,
            time: Int(Date().timeIntervalSince1970), sequence: 1
        )
        guard let reply = try await exchange(frame),
              let dps = reply["dps"] as? [String: Any],
              let on = dps[String(credentials.switchDP)] as? Bool
        else { throw PlugError.unexpectedReply }
        return on
    }

    // MARK: Connection

    private func exchange(_ frame: Data) async throws -> [String: Any]? {
        try await Self.retrying(attempts: attempts, delay: retryDelay) {
            try await exchangeOnce(frame)
        }
    }

    /// Runs `body` up to `attempts` times, waiting `delay` between tries. Only a
    /// dropped connection is retried; anything else fails straight away.
    static func retrying<T>(
        attempts: Int, delay: Duration, _ body: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch PlugError.dropped where attempt < attempts {
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private func exchangeOnce(_ frame: Data) async throws -> [String: Any]? {
        let connection = NWConnection(
            host: NWEndpoint.Host(credentials.host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp
        )
        let queue = DispatchQueue(label: "com.abhishek.awake.plug")
        defer { connection.cancel() }

        let reply: Data = try await withTimeout(timeout, cancelling: connection) {
            try await connect(connection, queue: queue)
            try await send(frame, on: connection)
            let header = try await receive(exactly: TuyaProtocol.headerLength, on: connection)
            guard let total = TuyaProtocol.frameLength(header: header) else { throw PlugError.unexpectedReply }
            return header + (try await receive(exactly: total - header.count, on: connection))
        }
        return try TuyaProtocol.decodeReply(reply, key: credentials.key)
    }

    private func connect(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run { continuation.resume(throwing: Self.failure(error)) }
                case .waiting(let error):
                    // "Waiting" means no route right now (e.g. Local Network access denied). Don't wait it out.
                    once.run { continuation.resume(throwing: PlugError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    once.run { continuation.resume(throwing: PlugError.timedOut) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.failure(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(exactly count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Self.failure(error))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    // Closed early: the dozing plug, or a wrong local key or protocol version.
                    continuation.resume(throwing: isComplete ? PlugError.dropped : PlugError.timedOut)
                }
            }
        }
    }

    /// A reset or abort from the plug is worth retrying; other errors are not.
    private static func failure(_ error: NWError) -> PlugError {
        if case .posix(let code) = error, [.ECONNRESET, .ECONNABORTED, .EPIPE].contains(code) {
            return .dropped
        }
        return .connectionFailed(error.localizedDescription)
    }

    /// Runs `body`, cancelling the connection after `seconds`. Cancelling is what
    /// unblocks the pending NWConnection callbacks, so the group can finish.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, cancelling connection: NWConnection,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                connection.cancel()
                throw PlugError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Guards a continuation that several callbacks could try to resume.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
