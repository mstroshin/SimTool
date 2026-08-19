#!/usr/bin/env swift
import Foundation

// Regenerates the shipped Swift literals from the authoring copies:
//
//   skills/<name>/*.md  →  Tool/Sources/SimToolCore/Skills/<Pascal>Skill.swift
//
// SKILL.md is the skill itself; every other .md in the directory ships as a
// companion document installed next to it (e.g. simtool's cartograph.md).
// AgentSkillTests asserts the copies are identical, but a test that only
// reports drift after the fact is not the same as not drifting. Run this after
// editing any of them, from the repository root:
//
//   swift Scripts/sync-agent-skills.swift

let indent = String(repeating: " ", count: 8)

func camelCase(_ name: String) -> String {
    let parts = name.split(separator: "-")
    return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.capitalized }.joined()
}

func pascalCase(_ name: String) -> String {
    name.split(separator: "-").map { $0.capitalized }.joined()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
let outputRoot = root.appendingPathComponent("Tool/Sources/SimToolCore/Skills", isDirectory: true)

guard let names = try? FileManager.default.contentsOfDirectory(atPath: skillsRoot.path).sorted(), !names.isEmpty else {
    FileHandle.standardError.write(Data("No skills/ directory here. Run this from the repository root.\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

// The literal for one Markdown file: every line indented to the closing
// delimiter's column, which Swift then strips — that is what makes the literal
// equal the file byte for byte. The raw literal's own delimiter cannot appear
// inside it, and quietly producing a file that does not compile is worse than
// stopping.
func literal(of markdown: String, file: String, property: String, source: String) -> String {
    guard !markdown.contains("\"\"\"#") else {
        FileHandle.standardError.write(Data("\(file): contains the literal's closing delimiter.\n".utf8))
        exit(1)
    }
    let body = markdown
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : indent + $0 }
        .joined(separator: "\n")
    return """
            /// Mirrored by `\(source)`, which is the copy to edit;
            /// regenerate this with `Scripts/sync-agent-skills.swift`.
            static let \(property) = #\"\"\"
        \(body)
        \(indent)\"\"\"#
        """
}

for name in names {
    let directory = skillsRoot.appendingPathComponent(name)
    let source = directory.appendingPathComponent("SKILL.md")
    guard let markdown = try? String(contentsOf: source, encoding: .utf8) else { continue }
    let property = camelCase(name)
    var literals = [literal(of: markdown, file: "SKILL.md", property: "\(property)Markdown", source: "skills/\(name)/SKILL.md")]

    let companionNames = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { $0.hasSuffix(".md") && $0 != "SKILL.md" }
        .sorted()
    var companionArguments: [String] = []
    var totalCharacters = markdown.count
    for companion in companionNames {
        guard let contents = try? String(contentsOf: directory.appendingPathComponent(companion), encoding: .utf8) else { continue }
        let companionProperty = property + pascalCase(String(companion.dropLast(".md".count))) + "Markdown"
        literals.append(literal(of: contents, file: companion, property: companionProperty, source: "skills/\(name)/\(companion)"))
        companionArguments.append("AgentSkill.Companion(fileName: \"\(companion)\", markdown: \(companionProperty))")
        totalCharacters += contents.count
    }

    let declaration = companionArguments.isEmpty
        ? "    public static let \(property) = AgentSkill(name: \"\(name)\", markdown: \(property)Markdown)"
        : """
            public static let \(property) = AgentSkill(
                name: "\(name)",
                markdown: \(property)Markdown,
                companions: [
        \(companionArguments.map { "            \($0)," }.joined(separator: "\n"))
                ]
            )
        """
    let contents = """
        extension AgentSkill {
        \(declaration)

        \(literals.joined(separator: "\n\n"))
        }

        """
    let destination = outputRoot.appendingPathComponent("\(pascalCase(name))Skill.swift")
    try Data(contents.utf8).write(to: destination, options: [.atomic])
    print("\(name) → \(destination.lastPathComponent) (\(totalCharacters) chars\(companionNames.isEmpty ? "" : ", +\(companionNames.joined(separator: ", "))"))")
}
