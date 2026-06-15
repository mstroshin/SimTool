import Foundation

public extension NetworkLoggerEvent {
    var displayApp: String {
        appBundleID ?? appDisplayName ?? ""
    }

    var displayRequest: String {
        switch networkProtocol {
        case .http:
            return [request.method, request.url ?? request.path]
                .compactMap { $0 }
                .joined(separator: " ")
        case .grpc:
            if let path = request.path { return path }
            return [request.grpcService, request.grpcMethod]
                .compactMap { $0 }
                .joined(separator: "/")
        }
    }

    var displayStatus: String {
        switch networkProtocol {
        case .http:
            return response?.statusCode.map(String.init) ?? ""
        case .grpc:
            return [response?.grpcStatusCode, response?.grpcStatusMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    var displayDuration: String {
        String(format: "%.0fms", durationMilliseconds)
    }
}
