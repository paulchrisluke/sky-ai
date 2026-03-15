import Foundation

enum WebSocketPublisherError: Error {
    case disconnected
    case invalidPayload
}

enum WebSocketConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(delaySeconds: Int)
}

final class WebSocketPublisher: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var onConnected: (@Sendable () -> Void)?
    private var onConnectionStateChanged: (@Sendable (WebSocketConnectionState) -> Void)?

    private let config: Config
    private let logger: Logger
    private let queue = DispatchQueue(label: "com.blawby.agent.websocket")

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var connected = false
    private var disconnectHandled = false
    private var reconnectAttempt = 0
    private var reconnectTask: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var allowReconnect = true

    init(config: Config, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    func setOnConnected(_ handler: (@Sendable () -> Void)?) {
        queue.async {
            self.onConnected = handler
        }
    }

    func setOnConnectionStateChanged(_ handler: (@Sendable (WebSocketConnectionState) -> Void)?) {
        queue.async {
            self.onConnectionStateChanged = handler
        }
    }

    func connect() {
        queue.async {
            self.allowReconnect = true
            self.startConnection()
        }
    }

    func disconnect() {
        queue.async {
            self.allowReconnect = false
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.stopPingTimer()
            self.connected = false
            self.publishConnectionState(.disconnected)
            self.socketTask?.cancel(with: .normalClosure, reason: nil)
            self.socketTask = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.logger.info("websocket disconnected")
        }
    }

    func isConnected() -> Bool {
        queue.sync { connected }
    }

    func send(type: String, payload: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.connected, let task = self.socketTask else {
                    continuation.resume(throwing: WebSocketPublisherError.disconnected)
                    return
                }

                guard let message = self.normalizedMessage(type: type, payload: payload) else {
                    continuation.resume(throwing: WebSocketPublisherError.invalidPayload)
                    return
                }

                task.send(.string(message)) { error in
                    if let error {
                        self.queue.async {
                            self.handleDisconnect(logMessage: "websocket send error \(error.localizedDescription)")
                        }
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func normalizedMessage(type: String, payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        object["type"] = type
        guard let normalized = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: normalized, encoding: .utf8)
    }

    private func startConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectHandled = false
        publishConnectionState(.connecting)

        let endpoint = "\(config.workerUrl)/agents/blawby-agent/primary?token=\(config.apiKey)"
        guard let url = URL(string: endpoint) else {
            logger.error("websocket invalid URL: \(endpoint)")
            return
        }

        session?.invalidateAndCancel()
        session = nil

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = newSession.webSocketTask(with: request)
        session = newSession
        socketTask = task

        logger.info("websocket connecting")
        task.resume()
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let strongSelf = self else { return }
            strongSelf.queue.async {
                guard task === strongSelf.socketTask else {
                    return
                }
                switch result {
                case let .success(message):
                    strongSelf.handleInboundMessage(message)
                    strongSelf.startReceiveLoop(for: task)
                case let .failure(error):
                    let ns = error as NSError
                    let code = task.closeCode.rawValue
                    strongSelf.handleDisconnect(
                        logMessage: "websocket receive error domain=\(ns.domain) code=\(ns.code) wsCloseCode=\(code) message=\(ns.localizedDescription)"
                    )
                }
            }
        }
    }

    private func handleInboundMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                return
            }
            if type == "pong" {
                logger.info("websocket pong")
            }
        case let .data(data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                return
            }
            if type == "pong" {
                logger.info("websocket pong")
            }
        @unknown default:
            return
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        pingTimer = timer
        timer.resume()
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        guard connected, let task = socketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "ping"]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(json)) { [self] error in
            if let error {
                self.handlePingSendFailure(error, task: task)
            }
        }
    }

    private func handlePingSendFailure(_ error: Error, task: URLSessionWebSocketTask) {
        queue.async { [self] in
            guard task === self.socketTask else {
                return
            }
            self.handleDisconnect(logMessage: "websocket ping error \(error.localizedDescription)")
        }
    }

    private func scheduleReconnect() {
        guard allowReconnect else { return }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 5.0, 60.0)
        logger.info("websocket reconnect in \(Int(delay))s")
        publishConnectionState(.reconnecting(delaySeconds: Int(delay)))

        let task = DispatchWorkItem { [weak self] in
            self?.startConnection()
        }
        reconnectTask = task
        queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func handleDisconnect(logMessage: String) {
        guard !disconnectHandled else { return }
        disconnectHandled = true

        connected = false
        publishConnectionState(.disconnected)
        stopPingTimer()
        logger.error(logMessage)

        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil

        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async {
            guard webSocketTask === self.socketTask else {
                return
            }
            self.disconnectHandled = false
            self.connected = true
            self.publishConnectionState(.connected)
            self.reconnectAttempt = 0
            self.logger.info("websocket connected")
            self.startReceiveLoop(for: webSocketTask)
            self.startPingTimer()
            self.onConnected?()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            guard webSocketTask === self.socketTask else {
                return
            }
            let reasonText: String
            if let reason, !reason.isEmpty {
                reasonText = String(data: reason, encoding: .utf8) ?? "<binary:\(reason.count)>"
            } else {
                reasonText = "<none>"
            }
            self.handleDisconnect(logMessage: "websocket closed code=\(closeCode.rawValue) reason=\(reasonText)")
        }
    }

    private func publishConnectionState(_ state: WebSocketConnectionState) {
        onConnectionStateChanged?(state)
    }
}
