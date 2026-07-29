#!/usr/bin/env swift
import Foundation

// Regenerates the shipped Swift literals from the authoring copies:
//
//   skills/<name>/SKILL.md  →  Tool/Sources/SimToolCore/Skills/<Pascal>Skill.swift
//
// AgentSkillTests asserts the two are identical, but a test that only reports
// drift after the fact is not the same as not drifting. Run this after editing
// any SKILL.md, from the repository root:
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

for name in names {
    let source = skillsRoot.appendingPathComponent(name).appendingPathComponent("SKILL.md")
    guard let markdown = try? String(contentsOf: source, encoding: .utf8) else { continue }
    // The raw literal's own delimiter cannot appear inside it, and quietly
    // producing a file that does not compile is worse than stopping.
    guard !markdown.contains("\"\"\"#") else {
        FileHandle.standardError.write(Data("\(name): SKILL.md contains the literal's closing delimiter.\n".utf8))
        exit(1)
    }
    // Every line indented to the closing delimiter's column, which Swift then
    // strips: that is what makes the literal equal the file byte for byte.
    let body = markdown
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : indent + $0 }
        .joined(separator: "\n")
    let property = camelCase(name)
    let contents = """
        extension AgentSkill {
            public static let \(property) = AgentSkill(name: "\(name)", markdown: \(property)Markdown)

            /// Mirrored by `skills/\(name)/SKILL.md`, which is the copy to edit;
            /// regenerate this with `Scripts/sync-agent-skills.swift`.
            static let \(property)Markdown = #\"\"\"
        \(body)
        \(indent)\"\"\"#
        }

        """
    let destination = outputRoot.appendingPathComponent("\(pascalCase(name))Skill.swift")
    try Data(contents.utf8).write(to: destination, options: [.atomic])
    print("\(name) → \(destination.lastPathComponent) (\(markdown.count) chars)")
}
