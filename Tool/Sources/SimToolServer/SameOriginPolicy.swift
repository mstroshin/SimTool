import Foundation
import SimToolCore
import Swifter

/// Who may talk to the server: its own viewer, and clients that are not
/// browsers — the CLI, an agent's curl, the app-side loggers posting from the
/// simulator. A page on any other origin may neither read a response nor make
/// the server act (a tap, a mock, a deleted run), nor frame the viewer to
/// steer clicks into it; a name that merely resolves to this Mac — DNS
/// rebinding — does not make a page same-origin.
///
/// Browsers' own local-network protections differ, so none is relied on: a
/// browser names the page behind every request it sends (`Origin`,
/// `Sec-Fetch-Site`) and the host it thinks it is talking to (`Host`), and the
/// server refuses what is not its own. Clients that are not browsers send
/// neither page header and are let through — they could do anything anyway.
struct SameOriginPolicy: Sendable {
    /// The host the server was started on, allowed besides loopback names
    /// and IP addresses.
    let serverHost: String

    /// Why the request is refused, or nil when it may go on. `headers` are
    /// keyed by lowercased name, as Swifter parses them; `path` has no query.
    func rejection(method: String, path: String, headers: [String: String]) -> String? {
        let host = headers["host"]
        if let host, !isAllowedHost(host) {
            return "Host \(host) is not an address of this SimTool server; open it at 127.0.0.1 or localhost"
        }
        if let origin = headers["origin"] {
            guard let host, origin.lowercased() == "http://" + host.lowercased() else {
                return "Origin \(origin) is not this server's viewer; SimTool answers only its own page"
            }
        }
        // What another page sends without an Origin: an <img>, <script> or
        // <video> pointed at the server, an <iframe>, a window it opens on an
        // API route. A link elsewhere may open the viewer itself, in a tab.
        if let site = headers["sec-fetch-site"]?.lowercased(), site == "cross-site" || site == "same-site" {
            let opensTheViewer = method == "GET" && path == "/"
                && headers["sec-fetch-mode"]?.lowercased() == "navigate"
                && headers["sec-fetch-dest"]?.lowercased() == "document"
            if !opensTheViewer {
                return "A \(site) request is not from this server's viewer; SimTool answers only its own page"
            }
        }
        return nil
    }

    func isAllowedHost(_ header: String) -> Bool {
        guard !header.isEmpty, header.unicodeScalars.allSatisfy(Self.hostCharacters.contains) else { return false }
        let name = Self.hostname(of: header).lowercased()
        guard !name.isEmpty else { return false }
        // Not *.localhost: a browser may resolve those through DNS, and a
        // resolver on the network then decides where they point.
        if name == "localhost" || name == serverHost.lowercased() { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }

    /// The response as the policy lets it out: without any CORS header a route
    /// set, with `nosniff`, a same-origin resource policy and no framing by
    /// another page, and — when it is a page — with the content security policy.
    func secured(_ response: HttpResponse, host: String?) -> HttpResponse {
        if case .switchProtocols = response { return response }
        var headers = response.headers().filter { !$0.key.lowercased().hasPrefix("access-control-") }
        let writer: ((HttpResponseBodyWriter) throws -> Void)?
        switch response {
        case let .raw(_, _, _, rawWriter):
            writer = rawWriter
        case let .ok(body):
            writer = Self.writer(for: body, headers: &headers)
        case let .badRequest(body?):
            writer = Self.writer(for: body, headers: &headers)
        default:
            writer = nil
            headers["Content-Length"] = "0"
        }
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Cross-Origin-Resource-Policy"] = "same-origin"
        headers["X-Frame-Options"] = "DENY"
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.hasPrefix("text/html") {
            headers["Content-Security-Policy"] = contentSecurityPolicy(host: host)
        }
        return .raw(response.statusCode, response.reasonPhrase, headers, writer)
    }

    /// What a page of this server may load and run: its own files only, no
    /// inline script, no plugin, no form posting elsewhere, no frame around it.
    /// Style attributes stay allowed — the viewer positions rulers and bars
    /// with them — while `<style>` elements must come from the server too. The
    /// live-input socket is named explicitly; not every browser counts ws: as
    /// 'self' (an IPv6 host cannot be written as a source, and is never needed:
    /// the server listens on IPv4).
    func contentSecurityPolicy(host: String?) -> String {
        let socket = host.flatMap { isAllowedHost($0) && !$0.hasPrefix("[") ? " ws://\($0)" : nil } ?? ""
        return [
            "default-src 'none'",
            "script-src 'self'",
            "style-src 'self'",
            "style-src-attr 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "media-src 'self' blob:",
            "connect-src 'self'\(socket)",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
    }

    func forbidden(_ reason: String) -> HttpResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": reason], options: [.withoutEscapingSlashes])) ?? Data()
        return secured(.raw(403, "Forbidden", ["Content-Type": "application/json", "Content-Length": "\(body.count)"]) {
            try $0.write(body)
        }, host: nil)
    }

    /// Letters, digits and what a host and port are written with — nothing
    /// that could end a header value or start another policy directive.
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")

    /// "127.0.0.1:3200" → "127.0.0.1", "[::1]:3200" → "::1".
    private static func hostname(of header: String) -> String {
        if header.hasPrefix("[") {
            guard let close = header.firstIndex(of: "]") else { return "" }
            return String(header[header.index(after: header.startIndex)..<close])
        }
        guard let colon = header.lastIndex(of: ":") else { return header }
        return String(header[..<colon])
    }

    /// The bytes Swifter would have written for `body`, ready for `.raw`.
    private static func writer(for body: HttpResponseBody, headers: inout [String: String]) -> (HttpResponseBodyWriter) throws -> Void {
        let data: Data
        switch body {
        case let .json(object):
            data = JSONSerialization.isValidJSONObject(object) ? (try? JSONSerialization.data(withJSONObject: object)) ?? Data() : Data()
        case let .html(text), let .text(text):
            data = Data(text.utf8)
        case let .htmlBody(text):
            data = Data("<html><meta charset=\"UTF-8\"><body>\(text)</body></html>".utf8)
            headers["Content-Type"] = headers["Content-Type"] ?? "text/html"
        case let .data(bytes, _):
            data = bytes
        case let .custom(object, serialize):
            data = (try? serialize(object)).map { Data($0.utf8) } ?? Data()
        }
        headers["Content-Length"] = "\(data.count)"
        return { try $0.write(data) }
    }
}

/// An `HttpServer` whose every route — the ones there now, the ones added
/// later, Swifter's own 404 — answers through `SameOriginPolicy`: a refused
/// request never reaches its route, and every response leaves secured.
final class SameOriginHttpServer: HttpServer {
    let policy: SameOriginPolicy
    /// Hears of every request the policy lets through, before it is handled.
    var onRequest: ((HttpRequest) -> Void)?

    init(policy: SameOriginPolicy) {
        self.policy = policy
        super.init()
    }

    override func dispatch(_ request: HttpRequest) -> ([String: String], (HttpRequest) -> HttpResponse) {
        if let reason = policy.rejection(method: request.method, path: request.path, headers: request.headers) {
            DebugLog.write("server", "refused \(request.method) \(request.path): \(reason)")
            let refusal = policy.forbidden(reason)
            return ([:], { _ in refusal })
        }
        onRequest?(request)
        let host = request.headers["host"]
        let (params, handler) = super.dispatch(request)
        return (params, { [policy] request in policy.secured(handler(request), host: host) })
    }
}
