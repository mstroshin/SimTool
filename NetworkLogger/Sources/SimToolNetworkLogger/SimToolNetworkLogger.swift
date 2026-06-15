import Foundation

public final class SimToolNetworkLogger: @unchecked Sendable {
    public static let shared = SimToolNetworkLogger()

    /// Builds a logger from process environment, or `nil` when capture is not enabled.
    ///
    /// A host app calls this once and holds the returned instance; `nil` means the host should
    /// perform no capture. See `NetworkLoggerConfiguration.fromEnvironment`.
    public static func makeFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimToolNetworkLogger? {
        guard let configuration = NetworkLoggerConfiguration.fromEnvironment(environment) else { return nil }
        return SimToolNetworkLogger(configuration: configuration)
    }

    /// Builds a logger from the environment and, **only in the simulator**, a persisted activation
    /// marker, so app-emitted network events keep flowing after a cold relaunch that drops the
    /// `SIMTOOL_*` environment (icon tap, Xcode run). Returns `nil` when capture should not run.
    ///
    /// Prefer this over `makeFromEnvironment(_:)` for simulator development. See
    /// `NetworkLoggerConfiguration.resolved(environment:isSimulator:activationStore:defaultServerURL:)`.
    public static func resolved(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimToolNetworkLogger? {
        guard let configuration = NetworkLoggerConfiguration.resolved(environment: environment) else { return nil }
        return SimToolNetworkLogger(configuration: configuration)
    }

    public let configuration: NetworkLoggerConfiguration

    private let sinks: [any NetworkLoggerSink]

    public init(configuration: NetworkLoggerConfiguration = NetworkLoggerConfiguration(), sinks: [any NetworkLoggerSink]? = nil) {
        self.configuration = configuration
        if let sinks {
            self.sinks = sinks
        } else {
            var configuredSinks: [any NetworkLoggerSink] = []
            if configuration.fileSinkEnabled {
                configuredSinks.append(NetworkLoggerFileSink(maxFileBytes: configuration.maxFileBytes))
            }
            if let serverSinkURL = configuration.serverSinkURL {
                configuredSinks.append(NetworkLoggerServerSink(serverURL: serverSinkURL, timeout: configuration.serverDeliveryTimeout))
            }
            self.sinks = configuredSinks
        }
    }

    public func instrument(_ configuration: URLSessionConfiguration) {
        NetworkLoggerURLProtocol.logger = self
        var protocolClasses = configuration.protocolClasses ?? []
        if !protocolClasses.contains(where: { $0 == NetworkLoggerURLProtocol.self }) {
            protocolClasses.insert(NetworkLoggerURLProtocol.self, at: 0)
        }
        configuration.protocolClasses = protocolClasses
    }

    public func instrumentedConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        instrument(configuration)
        return configuration
    }

    public func emit(_ event: NetworkLoggerEvent) {
        Task { await record(event) }
    }

    public func record(_ event: NetworkLoggerEvent) async {
        await record([event])
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        let batches = events.chunked(size: max(1, configuration.batchSize))
        for batch in batches {
            for sink in sinks {
                await sink.record(batch)
            }
        }
    }

    @discardableResult
    public func recordHTTP(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) async -> NetworkLoggerEvent {
        let event = makeHTTPEvent(
            request: request,
            response: response,
            requestBody: requestBody,
            responseBody: responseBody,
            durationMilliseconds: durationMilliseconds,
            error: error,
            rawMetadata: rawMetadata
        )
        await record(event)
        return event
    }

    public func makeHTTPEvent(
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) -> NetworkLoggerEvent {
        let body = requestBody ?? request.httpBody
        let requestMetadata = NetworkLoggerRequest(
            method: request.httpMethod,
            url: request.url?.absoluteString,
            host: request.url?.host,
            path: request.url?.path,
            headers: NetworkLoggerRedactor.redacted(request.allHTTPHeaderFields ?? [:], configuration: configuration.redaction),
            bodyByteCount: body?.count,
            bodyPreview: configuration.captureBodyPreviews ? NetworkLoggerRedactor.preview(data: body, maxBytes: configuration.maxBodyPreviewBytes) : nil
        )
        let responseMetadata = response.map {
            NetworkLoggerResponse(
                statusCode: $0.statusCode,
                headers: NetworkLoggerRedactor.redacted($0.stringHeaders, configuration: configuration.redaction),
                bodyByteCount: responseBody?.count,
                bodyPreview: configuration.captureBodyPreviews ? NetworkLoggerRedactor.preview(data: responseBody, maxBytes: configuration.maxBodyPreviewBytes) : nil
            )
        }
        return NetworkLoggerEvent(
            appBundleID: configuration.appBundleID,
            appDisplayName: configuration.appDisplayName,
            networkProtocol: .http,
            durationMilliseconds: durationMilliseconds,
            request: requestMetadata,
            response: responseMetadata,
            error: error.map(NetworkLoggerError.init),
            rawMetadata: rawMetadata
        )
    }

    public func startGRPCCall(
        service: String? = nil,
        method: String? = nil,
        fullMethod: String? = nil,
        authority: String? = nil,
        requestMetadata: [String: String] = [:],
        requestMessageBytes: Int? = nil,
        requestMessagePreview: String? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) -> NetworkLoggerGRPCRecorder {
        NetworkLoggerGRPCRecorder(
            logger: self,
            service: service,
            method: method,
            fullMethod: fullMethod,
            authority: authority,
            requestMetadata: requestMetadata,
            requestMessageBytes: requestMessageBytes,
            requestMessagePreview: requestMessagePreview,
            rawMetadata: rawMetadata
        )
    }

    @discardableResult
    public func recordGRPC(
        service: String? = nil,
        method: String? = nil,
        fullMethod: String? = nil,
        authority: String? = nil,
        requestMetadata: [String: String] = [:],
        responseMetadata: [String: String] = [:],
        statusCode: String? = nil,
        statusMessage: String? = nil,
        requestMessageBytes: Int? = nil,
        responseMessageBytes: Int? = nil,
        requestMessagePreview: String? = nil,
        responseMessagePreview: String? = nil,
        durationMilliseconds: Double,
        error: Error? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:]
    ) async -> NetworkLoggerEvent {
        let request = NetworkLoggerRequest(
            path: fullMethod,
            bodyPreview: boundedMessagePreview(requestMessagePreview),
            grpcService: service,
            grpcMethod: method,
            grpcAuthority: authority,
            metadata: NetworkLoggerRedactor.redacted(requestMetadata, configuration: configuration.redaction),
            messageByteCount: requestMessageBytes
        )
        let response = NetworkLoggerResponse(
            bodyPreview: boundedMessagePreview(responseMessagePreview),
            grpcStatusCode: statusCode,
            grpcStatusMessage: statusMessage,
            metadata: NetworkLoggerRedactor.redacted(responseMetadata, configuration: configuration.redaction),
            messageByteCount: responseMessageBytes
        )
        let event = NetworkLoggerEvent(
            appBundleID: configuration.appBundleID,
            appDisplayName: configuration.appDisplayName,
            networkProtocol: .grpc,
            durationMilliseconds: durationMilliseconds,
            request: request,
            response: response,
            error: error.map(NetworkLoggerError.init),
            rawMetadata: rawMetadata
        )
        await record(event)
        return event
    }

    /// Bounds a host-provided message preview to the configured ceiling when body capture is on.
    private func boundedMessagePreview(_ preview: String?) -> String? {
        guard configuration.captureBodyPreviews, let preview, !preview.isEmpty else { return nil }
        return NetworkLoggerRedactor.preview(data: Data(preview.utf8), maxBytes: configuration.maxBodyPreviewBytes)
    }
}

public struct NetworkLoggerGRPCRecorder: Sendable {
    private let logger: SimToolNetworkLogger
    private let startedAt: Date
    private let service: String?
    private let method: String?
    private let fullMethod: String?
    private let authority: String?
    private let requestMetadata: [String: String]
    private let requestMessageBytes: Int?
    private let requestMessagePreview: String?
    private let rawMetadata: [String: NetworkLoggerJSONValue]

    fileprivate init(
        logger: SimToolNetworkLogger,
        service: String?,
        method: String?,
        fullMethod: String?,
        authority: String?,
        requestMetadata: [String: String],
        requestMessageBytes: Int?,
        requestMessagePreview: String?,
        rawMetadata: [String: NetworkLoggerJSONValue]
    ) {
        self.logger = logger
        self.startedAt = Date()
        self.service = service
        self.method = method
        self.fullMethod = fullMethod
        self.authority = authority
        self.requestMetadata = requestMetadata
        self.requestMessageBytes = requestMessageBytes
        self.requestMessagePreview = requestMessagePreview
        self.rawMetadata = rawMetadata
    }

    @discardableResult
    public func finish(
        responseMetadata: [String: String] = [:],
        statusCode: String? = nil,
        statusMessage: String? = nil,
        responseMessageBytes: Int? = nil,
        responseMessagePreview: String? = nil,
        error: Error? = nil
    ) async -> NetworkLoggerEvent {
        await logger.recordGRPC(
            service: service,
            method: method,
            fullMethod: fullMethod,
            authority: authority,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
            statusCode: statusCode,
            statusMessage: statusMessage,
            requestMessageBytes: requestMessageBytes,
            responseMessageBytes: responseMessageBytes,
            requestMessagePreview: requestMessagePreview,
            responseMessagePreview: responseMessagePreview,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
            error: error,
            rawMetadata: rawMetadata
        )
    }
}

private final class NetworkLoggerURLProtocol: URLProtocol {
    static var logger: SimToolNetworkLogger?
    private static let handledKey = "SimToolNetworkLoggerHandled"
    private static let forwardingSession = URLSession(configuration: .default)

    private var forwardingTask: URLSessionDataTask?
    private var startedAt = Date()

    override class func canInit(with request: URLRequest) -> Bool {
        guard logger != nil,
              URLProtocol.property(forKey: handledKey, in: request) == nil,
              let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startedAt = Date()
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        let forwardedRequest = mutableRequest as URLRequest
        forwardingTask = Self.forwardingSession.dataTask(with: forwardedRequest) { [weak self] data, response, error in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            let duration = Date().timeIntervalSince(self.startedAt) * 1_000
            if let logger = Self.logger {
                Task {
                    await logger.recordHTTP(
                        request: forwardedRequest,
                        response: httpResponse,
                        requestBody: forwardedRequest.httpBody,
                        responseBody: data,
                        durationMilliseconds: duration,
                        error: error
                    )
                }
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
    }
}

private extension HTTPURLResponse {
    var stringHeaders: [String: String] {
        allHeaderFields.reduce(into: [:]) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<next]))
            index = next
        }
        return chunks
    }
}
