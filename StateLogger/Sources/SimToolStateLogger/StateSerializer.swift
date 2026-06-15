// StateLogger/Sources/SimToolStateLogger/StateSerializer.swift
import Foundation

/// Converts property values into `SimToolStateValue` JSON, emitting ONLY scalars and
/// collections of scalars. Un-annotated nested structs/classes reduce to a
/// `"<TypeName>"` placeholder; `@SimToolDebugState` models (`SimToolStateExpandable`)
/// expand via their own generated snapshot, cycle-guarded. Resolution order:
/// passthrough → optional unwrap → scalars → reportable → collections/dictionaries/enums
/// (elements by the same rule) → placeholder. Serialization never throws out of a
/// snapshot; placeholders are stable strings, so hidden objects produce no diff noise.
@MainActor
public enum SimToolStateSerializer {
    public static func serialize(_ value: Any, visited: inout Set<ObjectIdentifier>) -> SimToolStateValue {
        if let already = value as? SimToolStateValue { return already }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return .null }
            return serialize(child.value, visited: &visited)
        }

        switch value {
        case let primitive as Bool: return .bool(primitive)
        case let primitive as String: return .string(primitive)
        case let primitive as Int: return .number(Double(primitive))
        case let primitive as Int8: return .number(Double(primitive))
        case let primitive as Int16: return .number(Double(primitive))
        case let primitive as Int32: return .number(Double(primitive))
        case let primitive as Int64: return .number(Double(primitive))
        case let primitive as UInt: return .number(Double(primitive))
        case let primitive as UInt8: return .number(Double(primitive))
        case let primitive as UInt16: return .number(Double(primitive))
        case let primitive as UInt32: return .number(Double(primitive))
        case let primitive as UInt64: return .number(Double(primitive))
        case let primitive as Double: return .number(primitive)
        case let primitive as Float: return .number(Double(primitive))
        case let primitive as Date: return .string(iso8601.string(from: primitive))
        case let primitive as URL: return .string(primitive.absoluteString)
        case is Data: return placeholder(for: value)  // Mirror may report Data as a collection of bytes
        default: break
        }

        if let expandable = value as? any SimToolStateExpandable {
            // Cycle guard applies to class instances only; value types cannot
            // self-reference. The generated class snapshot method inserts the
            // instance into `visited` itself.
            if type(of: value) is AnyClass {
                let object = value as AnyObject
                if visited.contains(ObjectIdentifier(object)) {
                    return .string("<cycle: \(type(of: value))>")
                }
                var snapshot = expandable._simToolSnapshot(visited: &visited)
                // A nested model that is itself tracked carries its modelId, so
                // the viewer can fold its standalone change history into the
                // parent's diff instead of showing the same change twice.
                if let modelId = SimToolStateTrackedRegistry.modelIds[ObjectIdentifier(object)],
                   case .object(var fields) = snapshot {
                    fields["$modelId"] = .string(modelId)
                    snapshot = .object(fields)
                }
                return snapshot
            }
            return expandable._simToolSnapshot(visited: &visited)
        }

        switch mirror.displayStyle {
        case .collection, .set:
            return .array(mirror.children.map { serialize($0.value, visited: &visited) })
        case .dictionary:
            var object: [String: SimToolStateValue] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                guard pair.count == 2 else { continue }
                object[String(describing: pair[0])] = serialize(pair[1], visited: &visited)
            }
            return .object(object)
        case .enum:
            guard let child = mirror.children.first, let label = child.label else {
                return .string(String(describing: value))
            }
            return .object([label: serialize(child.value, visited: &visited)])
        default:
            return placeholder(for: value)
        }
    }

    private static func placeholder(for value: Any) -> SimToolStateValue {
        .string("<\(type(of: value))>")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
