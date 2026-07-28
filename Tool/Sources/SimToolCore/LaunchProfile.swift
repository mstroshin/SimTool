import Foundation

/// A YAML scalar read as its literal text. Launch arguments are argv, so
/// `-RemoteConfig some_flag true` must survive YAML typing `true` as a Bool and
/// `1234` as an Int — the app receives argv as strings either way.
public struct YAMLScalarText: Decodable, Equatable, Sendable {
    public var text: String

    public init(_ text: String) { self.text = text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { text = value; return }
        if let value = try? container.decode(Bool.self) { text = value ? "true" : "false"; return }
        if let value = try? container.decode(Int.self) { text = String(value); return }
        if let value = try? container.decode(Double.self) { text = String(value); return }
        throw DecodingError.typeMismatch(String.self, DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Expected a YAML scalar (string, number or boolean)."
        ))
    }
}

/// Substitutes `${VAR}` references from an environment. Credentials and
/// account identifiers belong in the shell, not in a file that travels with a
/// test, so a profile refers to them by name and resolution fails loudly when
/// one is missing — an empty account argument silently logs in as nobody.
public enum LaunchVariables {
    public static func expand(
        _ text: String,
        using environment: [String: String],
        context: String
    ) throws -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            result += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "}") else {
                throw SimToolError("\(context): unterminated `${` in \"\(text)\".")
            }
            let name = String(afterOpen[afterOpen.startIndex..<close])
            guard !name.isEmpty else {
                throw SimToolError("\(context): empty variable reference `${}` in \"\(text)\".")
            }
            guard let value = environment[name] else {
                throw SimToolError("\(context): `${\(name)}` is not set in the environment. Export it before running, or inline the value.")
            }
            result += value
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        return result + rest
    }
}

/// A named launch recipe from `.simtool/config.yml`: the app-specific launch
/// arguments and environment that a test refers to by name.
///
/// SimTool knows nothing about `-Environment`, accounts, or an app's
/// UI-testing master switch, and it must not: it drives any app. Keeping those
/// in the project config is what lets a test stay short, readable, and free of
/// credentials while still saying which account and environment it needs.
public struct LaunchProfile: Codable, Equatable, Sendable {
    public var name: String
    /// argv forwarded verbatim after the bundle id.
    public var arguments: [String]
    /// Process environment for the app, exported as `SIMCTL_CHILD_*`.
    public var environment: [String: String]
    /// Opened after launch, once the app is running.
    public var deeplink: String?

    public init(
        name: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        deeplink: String? = nil
    ) {
        self.name = name
        self.arguments = arguments
        self.environment = environment
        self.deeplink = deeplink
    }
}

/// The launch configuration of one test run after the profile, the test's
/// inline overrides and `${VAR}` substitution have been folded together.
public struct ResolvedLaunch: Codable, Equatable, Sendable {
    /// The profile this launch started from, when it named one.
    public var profile: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var deeplink: String?

    public init(
        profile: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        deeplink: String? = nil
    ) {
        self.profile = profile
        self.arguments = arguments
        self.environment = environment
        self.deeplink = deeplink
    }

    public var isEmpty: Bool {
        profile == nil && arguments.isEmpty && environment.isEmpty && deeplink == nil
    }

    /// Resolves `${VAR}` in every argument, environment value and the deeplink.
    public func resolvingVariables(
        using variables: [String: String],
        context: String
    ) throws -> ResolvedLaunch {
        ResolvedLaunch(
            profile: profile,
            arguments: try arguments.map { try LaunchVariables.expand($0, using: variables, context: context) },
            environment: try environment.reduce(into: [:]) { result, pair in
                result[pair.key] = try LaunchVariables.expand(pair.value, using: variables, context: context)
            },
            deeplink: try deeplink.map { try LaunchVariables.expand($0, using: variables, context: context) }
        )
    }
}
