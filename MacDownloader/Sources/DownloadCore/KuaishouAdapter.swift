import Foundation

public struct HTTPFetchResult: Sendable {
    public let data: Data
    public let finalURL: URL
    public let statusCode: Int
    public init(data: Data, finalURL: URL, statusCode: Int) {
        self.data = data; self.finalURL = finalURL; self.statusCode = statusCode
    }
}

public protocol HTTPFetching: Sendable {
    func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult
}

/// Each request owns a cookie-free session which is cancelled and invalidated on exit.
/// Response bytes are bounded while streaming, before appending to the buffer.
public final class AnonymousHTTPClient: HTTPFetching, @unchecked Sendable {
    public init() {}

    public func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        try await BoundedHTTPFetchOperation(maximumBytes: 8 * 1_024 * 1_024, responseOnly: false).run(url, headers: headers)
    }

    /// Resolve a share redirect with GET semantics without downloading its landing page.
    func resolveURL(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        try await BoundedHTTPFetchOperation(maximumBytes: 0, responseOnly: true).run(url, headers: headers)
    }
}

private final class BoundedHTTPFetchOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let responseOnly: Bool
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPFetchResult, Error>?
    private var terminalResult: Result<HTTPFetchResult, Error>?
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var redirects = 0
    private var deadline: DispatchSourceTimer?

    init(maximumBytes: Int, responseOnly: Bool) {
        self.maximumBytes = maximumBytes
        self.responseOnly = responseOnly
    }

    func run(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = terminalResult {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 20
                configuration.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url, timeoutInterval: 15)
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let newTask = newSession.dataTask(with: request)
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 20)
                timer.setEventHandler { [weak self] in self?.finish(.failure(DownloadError.timedOut)) }
                timer.resume()
                lock.lock()
                let cancelled = terminalResult != nil
                if !cancelled { session = newSession; task = newTask; deadline = timer }
                lock.unlock()
                if cancelled { newTask.cancel(); newSession.invalidateAndCancel(); timer.cancel() }
                else { newTask.resume() }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let permitted = terminalResult == nil && redirects <= 6 && request.url.map {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.user == nil && $0.password == nil
        } == true
        lock.unlock()
        completionHandler(permitted ? request : nil)
        if !permitted { finish(.failure(DownloadError.invalidMetadata)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
            completionHandler(.cancel); finish(.failure(DownloadError.invalidMetadata)); return
        }
        if responseOnly {
            completionHandler(.cancel)
            finish(.success(HTTPFetchResult(data: Data(), finalURL: finalURL, statusCode: response.statusCode)))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel); finish(.failure(DownloadError.outputTooLarge)); return
        }
        lock.lock()
        let cancelled = terminalResult != nil
        if !cancelled { self.response = response }
        lock.unlock()
        completionHandler(cancelled ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        let exceeded = data.count > maximumBytes - buffer.count
        if !exceeded { buffer.append(data) }
        lock.unlock()
        if exceeded { finish(.failure(DownloadError.outputTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            if error.code == .timedOut { finish(.failure(DownloadError.timedOut)) }
            else if error.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(DownloadError.processFailed(-1, "network " + String(error.code.rawValue)))) }
            return
        }
        if error != nil { finish(.failure(DownloadError.invalidMetadata)); return }
        lock.lock()
        let response = self.response
        let data = buffer
        lock.unlock()
        guard let response, let finalURL = response.url else { finish(.failure(DownloadError.invalidMetadata)); return }
        finish(.success(HTTPFetchResult(data: data, finalURL: finalURL, statusCode: response.statusCode)))
    }

    private func finish(_ result: Result<HTTPFetchResult, Error>) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = result
        let pending = continuation
        let oldTask = task
        let oldSession = session
        let oldDeadline = deadline
        continuation = nil; task = nil; session = nil; deadline = nil; response = nil
        buffer = Data()
        lock.unlock()
        oldDeadline?.cancel()
        oldTask?.cancel()
        oldSession?.invalidateAndCancel()
        pending?.resume(with: result)
    }
}

/// A narrow adapter for the public single-video share flow; no third-party parsing service is used.
struct KuaishouAdapter: Sendable {
    let http: any HTTPFetching
    static let referer = "https://live.kuaishou.com/"
    static let headers = ["User-Agent": "Mozilla/5.0", "Referer": referer]

    static func supports(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              host == "kuaishou.com" || host.hasSuffix(".kuaishou.com") else { return false }
        return host == "v.kuaishou.com" || url.path.hasPrefix("/short-video/") || url.path.hasPrefix("/f/")
    }

    func resolve(_ originalURL: URL) async throws -> VideoMetadata {
        var pageURL = originalURL
        if !pageURL.path.hasPrefix("/short-video/") {
            let response = try await http.fetch(pageURL, headers: Self.headers)
            guard (200..<400).contains(response.statusCode), Self.supports(response.finalURL) else {
                throw DownloadError.kuaishouShareLinkRequired
            }
            pageURL = response.finalURL
        }
        guard let identity = Self.identity(pageURL) else { throw DownloadError.kuaishouShareLinkRequired }
        var components = URLComponents(string: "https://live.kuaishou.com/live_api/profile/feedbyid")!
        components.queryItems = [URLQueryItem(name: "photoId", value: identity.photoID),
                                 URLQueryItem(name: "principalId", value: identity.authorID)]
        let response = try await http.fetch(components.url!, headers: Self.headers)
        guard (200..<300).contains(response.statusCode) else {
            throw DownloadError.processFailed(Int32(response.statusCode), "HTTP " + String(response.statusCode))
        }
        let metadata = try Self.parse(response.data, sourceURL: originalURL, webpageURL: pageURL)
        guard metadata.id == identity.photoID else { throw DownloadError.invalidMetadata }
        return metadata
    }

    static func identity(_ url: URL) -> (photoID: String, authorID: String)? {
        guard supports(url), url.path.hasPrefix("/short-video/"),
              let photoID = url.path.split(separator: "/").dropFirst().first.map(String.init),
              !photoID.isEmpty, photoID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let authorID = query.first(where: { $0.name == "authorId" })?.value, !authorID.isEmpty else { return nil }
        return (photoID, authorID)
    }

    static func parse(_ data: Data, sourceURL: URL, webpageURL: URL) throws -> VideoMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              (payload["result"] as? NSNumber)?.intValue == 1,
              let work = payload["currentWork"] as? [String: Any],
              let id = work["id"] as? String,
              let directString = work["playUrl"] as? String,
              let direct = URL(string: directString), direct.scheme?.lowercased() == "https",
              let host = direct.host?.lowercased(),
              ["kwimgs.com", "yximgs.com", "gifshow.com", "kuaishouzt.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw DownloadError.invalidMetadata
        }
        let author = (work["author"] as? [String: Any])?["name"] as? String
        let caption = work["caption"] as? String
        let title = (caption?.isEmpty == false ? caption : nil) ?? "快手视频" + (author.map { " · " + $0 } ?? "")
        let thumbnail = (work["poster"] as? String).flatMap(URL.init(string:))
        let width = (work["width"] as? NSNumber)?.intValue
        let height = (work["height"] as? NSNumber)?.intValue
        return VideoMetadata(id: id, sourceURL: sourceURL, webpageURL: webpageURL, title: title,
                             thumbnailURL: thumbnail, formats: [MediaFormat(id: "kuaishou-source", fileExtension: "mp4", width: width, height: height)],
                             extractor: "KuaishouShare", resolvedMediaURL: direct,
                             httpHeaders: ["Referer": referer, "User-Agent": "Mozilla/5.0"])
    }
}
