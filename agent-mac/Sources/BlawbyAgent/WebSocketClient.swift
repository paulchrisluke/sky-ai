import Foundation

final class AgentWebSocketClient: NSObject, URLSessionWebSocketDelegate {
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
    private var outboundQueue: [String] = []

    init(config: Config, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    func connect() {
        queue.async {
            self.startConnection()
        }
    }

    func enqueue(_ message: String) {
        queue.async {
            self.outboundQueue.append(message)
            self.flushQueueIfConnected()
        }
    }

    private func startConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectHandled = false

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
        startReceiveLoop()
    }

    private func startReceiveLoop() {
        guard let task = socketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(message):
                    self.handleInboundMessage(message)
                    self.startReceiveLoop()
                case let .failure(error):
                    self.handleDisconnect(logMessage: "websocket receive error \(error.localizedDescription)")
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

    private func flushQueueIfConnected() {
        guard connected, let task = socketTask else { return }
        while !outboundQueue.isEmpty {
            let message = outboundQueue.removeFirst()
            task.send(.string(message)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.queue.async {
                        self.handleDisconnect(logMessage: "websocket send error \(error.localizedDescription)")
                    }
                }
            }
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
        guard connected else { return }
        let payload = ["type": "ping"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        logger.info("websocket ping")
        enqueue(json)
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 5.0, 60.0)
        logger.info("websocket reconnect in \(Int(delay))s")

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
            self.disconnectHandled = false
            self.connected = true
            self.reconnectAttempt = 0
            self.logger.info("websocket connected")
            self.startPingTimer()
            self.flushQueueIfConnected()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            self.handleDisconnect(logMessage: "websocket closed code=\(closeCode.rawValue)")
        }
    }
}
