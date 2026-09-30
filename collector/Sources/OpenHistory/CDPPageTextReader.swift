import Foundation
import HistoryCore

/// Reads one page's text over the Chrome DevTools Protocol:
/// connect, one read-only `Runtime.evaluate`, disconnect.
///
/// A DevTools client that stays attached changes how the browser treats its
/// pages (an attached client that turns on focus emulation keeps every
/// background tab "visible", so they keep animating and repainting). This
/// reader therefore touches only the single page target it reads, sends
/// nothing but `CDPPageText.methods` (no `Emulation.*`, `Page.*`, `Target.*`
/// or domain enables), and closes the socket as soon as the reply arrives
/// or the deadline passes. The endpoint is always loopback; no proxy, cache
/// or cookies are used.
final class CDPPageTextReader {
    enum ReadError: Error {
        case listFailed(String)
        case noMatchingTarget
        case socketFailed(String)
        case reply(CDPPageText.ReplyError)
        case timedOut
    }

    private let queue = DispatchQueue(label: "open-history.page-text", qos: .utility)
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
    }

    /// Calls `completion` exactly once, on a background queue.
    func read(
        pageURL: String,
        title: String?,
        settings: PageTextSettings,
        completion: @escaping (Result<PageTextResult, ReadError>) -> Void
    ) {
        let operation = ReadOperation(
            session: session,
            pageURL: pageURL,
            title: title,
            settings: settings,
            completion: completion
        )
        queue.async {
            operation.start(on: self.queue)
        }
    }

    /// One read. All state is touched on the reader's serial queue.
    private final class ReadOperation {
        private let session: URLSession
        private let pageURL: String
        private let title: String?
        private let settings: PageTextSettings
        private var completion: ((Result<PageTextResult, ReadError>) -> Void)?
        private var listTask: URLSessionDataTask?
        private var socket: URLSessionWebSocketTask?
        private let requestID = 1

        init(
            session: URLSession,
            pageURL: String,
            title: String?,
            settings: PageTextSettings,
            completion: @escaping (Result<PageTextResult, ReadError>) -> Void
        ) {
            self.session = session
            self.pageURL = pageURL
            self.title = title
            self.settings = settings
            self.completion = completion
        }

        func start(on queue: DispatchQueue) {
            queue.asyncAfter(deadline: .now() + settings.effectiveTimeout) { [self] in
                finish(.failure(.timedOut))
            }
            guard let listURL = URL(string: "http://127.0.0.1:\(settings.port)/json/list") else {
                finish(.failure(.listFailed("bad port")))
                return
            }
            var request = URLRequest(url: listURL, timeoutInterval: settings.effectiveTimeout)
            request.httpMethod = "GET"
            let task = session.dataTask(with: request) { [self] data, response, error in
                queue.async { [self] in
                    listed(data: data, response: response, error: error)
                }
            }
            listTask = task
            task.resume()
        }

        private func listed(data: Data?, response: URLResponse?, error: Error?) {
            guard completion != nil else {
                return
            }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                finish(.failure(.listFailed(error?.localizedDescription ?? "no response")))
                return
            }
            guard let targets = try? CDPTarget.decodeList(data),
                  let match = CDPTargetMatcher.select(
                      targets,
                      pageURL: pageURL,
                      title: title,
                      port: settings.port
                  )
            else {
                finish(.failure(.noMatchingTarget))
                return
            }
            let socket = session.webSocketTask(with: match.socketURL)
            socket.maximumMessageSize = max(1 << 20, settings.effectiveMaxCharacters * 4 + (64 << 10))
            self.socket = socket
            socket.resume()
            guard let message = try? CDPPageText.evaluateMessageData(
                id: requestID,
                maxCharacters: settings.effectiveMaxCharacters
            ), let text = String(data: message, encoding: .utf8) else {
                finish(.failure(.socketFailed("encode")))
                return
            }
            socket.send(.string(text)) { [self] error in
                if let error {
                    finish(.failure(.socketFailed(error.localizedDescription)))
                } else {
                    receive()
                }
            }
        }

        private func receive() {
            guard completion != nil, let socket else {
                return
            }
            socket.receive { [self] result in
                switch result {
                case let .failure(error):
                    finish(.failure(.socketFailed(error.localizedDescription)))
                case let .success(message):
                    let data: Data
                    switch message {
                    case let .string(text):
                        data = Data(text.utf8)
                    case let .data(bytes):
                        data = bytes
                    @unknown default:
                        receive()
                        return
                    }
                    switch CDPPageText.parseReply(
                        data,
                        id: requestID,
                        maxCharacters: settings.effectiveMaxCharacters
                    ) {
                    case nil:
                        receive()
                    case let .success(page)?:
                        finish(.success(page))
                    case let .failure(error)?:
                        finish(.failure(.reply(error)))
                    }
                }
            }
        }

        /// Delivers the first result and closes everything; later calls
        /// (the deadline, a late reply) do nothing.
        private func finish(_ result: Result<PageTextResult, ReadError>) {
            guard let completion else {
                return
            }
            self.completion = nil
            listTask?.cancel()
            listTask = nil
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            completion(result)
        }
    }
}
