import Foundation

/// A loosely-typed JSON value. The stream-json protocol evolves with Claude
/// Code releases, so the app reads it leniently instead of with strict
/// Codable structs: unknown fields and new message types are ignored.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(parsing data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSONValue(any: any)
    }

    public init(parsing string: String) throws {
        try self.init(parsing: Data(string.utf8))
    }

    public init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber bridges both Bool and numbers; tell them apart.
            // JSON booleans arrive as char-typed NSNumbers ("c") on Darwin and Linux.
            if String(cString: n.objCType) == "c" { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]: self = .object(d.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Compact JSON text (sorted keys, for stable output).
    public func serialized(pretty: Bool = false) -> String {
        if case .string(let s) = self { return s }
        guard JSONSerialization.isValidJSONObject(any) else {
            if let d = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]) {
                return String(decoding: d, as: UTF8.self)
            }
            return ""
        }
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        let d = (try? JSONSerialization.data(withJSONObject: any, options: opts)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(nilLiteral: ()) { self = .null }
}

/// Splits a byte stream into newline-terminated lines (stream-json framing).
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    /// Appends bytes and returns every complete line (without the newline).
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    /// Whatever is left without a newline (at EOF).
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
