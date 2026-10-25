import Foundation
import Network

/// ChatGPT のモデル (`GET https://api.openai.com/v1/models` の 1 件)
public struct ChatGPTModel: Decodable, Identifiable, Hashable, Sendable {
    public var slug: String
    public var displayName: String
    public var id: String { slug }
}

public enum LoopbackError: Error, LocalizedError {
    case cannotListen(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .cannotListen(detail): "ChatGPT からの戻りを受け取る準備ができませんでした (\(detail))"
        case .timedOut: "ChatGPT での許可を待つ時間が過ぎました。もう一度試してください"
        case .cancelled: "ChatGPT への接続をやめました"
        }
    }
}

/// ChatGPT の許可のあと、ブラウザが戻ってくる http://127.0.0.1:<port>/auth/callback を受け取る。
/// 戻り先はこの端末 (iPhone) の 127.0.0.1。受け取ったアドレス (code・state) で接続を完了する。
public final class LoopbackCallback: @unchecked Sendable {
    public let port: UInt16
    public let path: String
    private let queue = DispatchQueue(label: "omimi.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var received: Result<URL, Error>?
    private var ready: CheckedContinuation<Void, Error>?
    private let successPage: String

    public init(port: UInt16 = 1455, path: String = "/auth/callback",
                successPage: String = "接続しています。この画面は自動で閉じます。") {
        self.port = port
        self.path = path
        self.successPage = successPage
    }

    public var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    /// 127.0.0.1 だけで待ち受けを始める (ブラウザを開く前に呼ぶ)
    public func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw LoopbackError.cannotListen(error.localizedDescription)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ready = ready
                // 状態の知らせはこのキューで届く
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let ready = self.ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        ready.resume()
                    case let .failed(error):
                        self.ready = nil
                        ready.resume(throwing: LoopbackError.cannotListen(error.localizedDescription))
                    case .cancelled:
                        self.ready = nil
                        ready.resume(throwing: LoopbackError.cancelled)
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    /// 戻ってきたアドレス (code・state を含む) を待つ
    public func waitForCallback(timeout: TimeInterval = 600) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                queue.async {
                    if let received = self.received {
                        c.resume(with: received)
                        return
                    }
                    self.continuation = c
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(LoopbackError.timedOut)) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(LoopbackError.cancelled)) }
        }
    }

    /// 待つのをやめる (利用者が許可の画面を閉じたときなど)
    public func cancel() {
        queue.async { self.finish(.failure(LoopbackError.cancelled)) }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard received == nil else { return }
        received = result
        continuation?.resume(with: result)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return conn.cancel() }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 1 行目: GET /auth/callback?code=...&state=... HTTP/1.1
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let ok = target.hasPrefix(self.path + "?") || target == self.path
            let body = ok
                ? "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>Omimi</title>"
                  + "<body style='font:17px/1.7 -apple-system,sans-serif;margin:30vh 24px;color:#1D2A44'>\(self.successPage)</body>"
                : "Not Found"
            let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n"
            conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
            if ok, let url = URL(string: "http://127.0.0.1:\(self.port)\(target)") {
                self.finish(.success(url))
            }
        }
    }
}
