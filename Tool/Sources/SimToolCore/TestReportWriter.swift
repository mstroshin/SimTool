import Foundation

/// Puts the run's Markdown report in the run's own directory.
///
/// Separate from the renderer so the file-writing half is testable without a
/// simulator, and so the executor's failure handling stays one call deep: a
/// report that could not be written is a note on the run, never a failed run.
public enum TestReportWriter {
    public static let fileName = "report.md"

    @discardableResult
    public static func write(
        session: TestSession,
        definition: TestDefinition?,
        requiredVariables: [String] = [],
        into directory: URL
    ) throws -> URL {
        let markdown = TestReportRenderer.render(
            session: session,
            definition: definition,
            requiredVariables: requiredVariables
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(markdown.utf8).write(to: url, options: [.atomic])
        return url
    }
}
