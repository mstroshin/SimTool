// StateLogger/Sources/SimToolStateLogger/StateTrackedRegistry.swift
import Foundation

/// Identity → modelId for instances currently tracked by `SimToolState`.
/// The serializer reads it to stamp nested tracked models with a `"$modelId"`
/// marker, which lets the viewer collapse a child's standalone change history
/// into the parent's diff. Kept outside `SimToolState` so the serializer
/// (no availability gate) can read it on any OS the package supports.
@MainActor
enum SimToolStateTrackedRegistry {
    static var modelIds: [ObjectIdentifier: String] = [:]
}
