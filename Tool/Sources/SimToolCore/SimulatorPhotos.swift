import Foundation
import UniformTypeIdentifiers

/// Adds images and videos to a simulator's Photos library, where a photo
/// picker offers them.
public enum SimulatorPhotosClient {
    public static func add(_ files: [URL], deviceUDID: String) async throws -> ProcessOutput {
        guard !files.isEmpty else { throw SimToolError("Nothing to add to Photos") }
        for file in files where MediaUpload.kind(ofExtension: file.pathExtension) == nil {
            throw SimToolError("\(file.lastPathComponent) is not an image or a video")
        }
        // The first import on a fresh simulator waits for the Photos library to
        // come up (~8 s); later ones take well under a second.
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "addmedia", deviceUDID] + files.map(\.path),
            timeoutSeconds: 120
        )
        guard output.status == 0 else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("Cannot add to Photos: \(detail.isEmpty ? "simctl addmedia failed" : detail)")
        }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        return ProcessOutput(status: 0, stdout: Data("Added \(names) to Photos.".utf8))
    }
}

/// Names a file uploaded to the server so `simctl addmedia` and `devicectl`
/// can tell its type: both go by the file extension.
public enum MediaUpload {
    public enum Kind: Equatable, Sendable {
        case image
        case video
    }

    public static func kind(ofExtension pathExtension: String) -> Kind? {
        guard let type = UTType(filenameExtension: pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }

    /// The client's file name, reduced to its last path component, when its
    /// extension names an image or a video; otherwise its stem (or `clipboard`)
    /// with the extension the Content-Type implies. Nil when neither says what
    /// the bytes are.
    public static func fileName(suggested: String?, contentType: String?) -> String? {
        // String-only path handling: a URL would resolve an empty name against
        // the working directory.
        let name = ((suggested ?? "") as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let usable = !stem.isEmpty && stem != "." && stem != ".." && !stem.contains("/")
        if usable, kind(ofExtension: (name as NSString).pathExtension) != nil { return name }

        let mimeType = contentType?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let mimeType,
              let pathExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension,
              kind(ofExtension: pathExtension) != nil else { return nil }
        return "\(usable ? stem : "clipboard").\(pathExtension)"
    }
}
