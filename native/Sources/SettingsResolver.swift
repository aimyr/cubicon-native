import Foundation

enum NativeSettingsResolver {
    struct ResolutionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private indirect enum Value: Decodable, Equatable {
        case number(Double), string(String), bool(Bool), array([Value]), function(String), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else { self = .array(try container.decode([Value].self)) }
        }

        static func setting(_ string: String) -> Value {
            if string == "true" { return .bool(true) }
            if string == "false" { return .bool(false) }
            if let number = Double(string), number.isFinite { return .number(number) }
            if string.hasPrefix("["), let data = string.data(using: .utf8), let list = try? JSONDecoder().decode([Value].self, from: data) { return .array(list) }
            return .string(string)
        }

        var truth: Bool {
            switch self {
            case .number(let value): return value != 0
            case .string(let value): return !value.isEmpty
            case .bool(let value): return value
            case .array(let value): return !value.isEmpty
            case .null: return false
            case .function: return true
            }
        }

        func numeric() throws -> Double {
            switch self {
            case .number(let number): return number
            case .bool(let value): return value ? 1 : 0
            default: throw ResolutionError(message: "A Cura setting expression expected a number.")
            }
        }

        func text() throws -> String {
            guard case .string(let string) = self else { throw ResolutionError(message: "A Cura setting expression expected a setting name.") }
            return string
        }

        func list() throws -> [Value] {
            guard case .array(let array) = self else { throw ResolutionError(message: "A Cura setting expression expected a list.") }
            return array
        }

        var foundation: Any {
            switch self {
            case .number(let value): return value
            case .string(let value): return value
            case .bool(let value): return value
            case .array(let values): return values.map(\.foundation)
            case .null: return NSNull()
            case .function(let name): return name
            }
        }

        func serialized() throws -> String {
            switch self {
            case .number(let value):
                guard value.isFinite else { throw ResolutionError(message: "A Cura setting expression produced a non-finite number.") }
                return value.rounded(.towardZero) == value && abs(value) < 9e15 ? String(Int64(value)) : String(value)
            case .string(let value): return value
            case .bool(let value): return value ? "true" : "false"
            case .array:
                return String(decoding: try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys]), as: UTF8.self)
            case .null: return ""
            case .function: throw ResolutionError(message: "A Cura expression returned an unevaluated function.")
            }
        }
    }

    private final class Node: Decodable {
        let kind: String
        let value: Value?
        let name: String?
        let op: String?
        let ops: [String]?
        let args: [Node]?

        func dependencies(knownKeys: Set<String>) -> Set<String> {
            var names = Set<String>()
            if kind == "name", let name, knownKeys.contains(name) { names.insert(name) }
            if kind == "constant", case .string(let value) = value, knownKeys.contains(value) { names.insert(value) }
            for argument in args ?? [] { names.formUnion(argument.dependencies(knownKeys: knownKeys)) }
            return names
        }
    }

    private struct Trees: Decodable {
        let schemaVersion: Int
        let expressions: [String: Node]
    }

    private static let lock = NSLock()
    private static var trees: [String: Node]?

    // Also used by the standalone command-line checks; the app loads the same
    // generated resource from its bundle without a Python runtime.
    static func registerExpressionTrees(data: Data) throws {
        let document = try JSONDecoder().decode(Trees.self, from: data)
        guard document.schemaVersion == 1 else { throw ResolutionError(message: "Unsupported Cura expression resource version.") }
        lock.lock()
        trees = document.expressions
        lock.unlock()
    }

    private static func expressionTrees() throws -> [String: Node] {
        lock.lock()
        let current = trees
        lock.unlock()
        if let current { return current }
        guard let url = Bundle.main.url(forResource: "Expressions", withExtension: "json") else {
            throw ResolutionError(message: "Expressions.json is missing from the native application bundle.")
        }
        try registerExpressionTrees(data: Data(contentsOf: url))
        lock.lock()
        defer { lock.unlock() }
        return trees ?? [:]
    }

    static func resolve(snapshot: [String: String], expressions: [String: String], overrides: [String: String], literalKeys: Set<String> = []) throws -> [String: String] {
        let trees = try expressionTrees()
        let known = Set(snapshot.keys).union(overrides.keys)
        var nodes = [String: Node]()
        var dependencies = [String: Set<String>]()
        for (key, expression) in expressions {
            guard let node = trees[expression] else { throw ResolutionError(message: "The native Cura expression resource does not contain setting \(key).") }
            nodes[key] = node
            dependencies[key] = node.dependencies(knownKeys: known)
        }
        var dirty = Set(overrides.keys)
        var changed = true
        while changed {
            changed = false
            for (key, references) in dependencies where !dirty.contains(key) && !references.isDisjoint(with: dirty) {
                dirty.insert(key)
                changed = true
            }
        }
        let evaluator = Evaluation(snapshot: snapshot, nodes: nodes, dirty: dirty, overrides: overrides, literalKeys: literalKeys)
        var result = snapshot
        for key in dirty {
            result[key] = try evaluator.get(key).serialized()
        }
        for (key, value) in overrides { result[key] = value }
        return result
    }

    private final class Evaluation {
        let snapshot: [String: String]
        let nodes: [String: Node]
        let dirty: Set<String>
        let overrides: [String: String]
        let literalKeys: Set<String>
        var cache = [String: Value]()
        var active = Set<String>()

        init(snapshot: [String: String], nodes: [String: Node], dirty: Set<String>, overrides: [String: String], literalKeys: Set<String>) {
            self.snapshot = snapshot
            self.nodes = nodes
            self.dirty = dirty
            self.overrides = overrides
            self.literalKeys = literalKeys
        }

        func get(_ key: String) throws -> Value {
            if let value = overrides[key] { return Value.setting(value) }
            if let cached = cache[key] { return cached }
            if dirty.contains(key), !literalKeys.contains(key), let node = nodes[key] {
                guard !active.contains(key) else { throw ResolutionError(message: "Cyclic Cura setting dependency: \(key).") }
                active.insert(key)
                defer { active.remove(key) }
                let value = try evaluate(node)
                cache[key] = value
                return value
            }
            guard let value = snapshot[key] else { throw ResolutionError(message: "Missing Cura setting: \(key).") }
            return Value.setting(value)
        }

        func evaluate(_ node: Node) throws -> Value {
            let arguments = node.args ?? []
            switch node.kind {
            case "constant": return node.value ?? .null
            case "name":
                let name = node.name ?? ""
                if name == "math.pi" { return .number(.pi) }
                if name == "abs" { return .function(name) }
                return try get(name)
            case "list": return .array(try arguments.map(evaluate))
            case "if": return try evaluate(evaluate(arguments[0]).truth ? arguments[1] : arguments[2])
            case "bool":
                var value = try evaluate(arguments[0])
                for argument in arguments.dropFirst() {
                    if node.op == "And" && !value.truth { return value }
                    if node.op == "Or" && value.truth { return value }
                    value = try evaluate(argument)
                }
                return value
            case "unary":
                let value = try evaluate(arguments[0])
                switch node.op {
                case "Not": return .bool(!value.truth)
                case "USub": return .number(try -value.numeric())
                case "UAdd": return .number(try value.numeric())
                default: throw ResolutionError(message: "Unsupported unary Cura expression.")
                }
            case "binary":
                let left = try evaluate(arguments[0]), right = try evaluate(arguments[1])
                if node.op == "Add", case .string(let lhs) = left, case .string(let rhs) = right { return .string(lhs + rhs) }
                let lhs = try left.numeric(), rhs = try right.numeric()
                switch node.op {
                case "Add": return .number(lhs + rhs)
                case "Sub": return .number(lhs - rhs)
                case "Mult": return .number(lhs * rhs)
                case "Div": guard rhs != 0 else { throw ResolutionError(message: "Division by zero in Cura settings.") }; return .number(lhs / rhs)
                case "FloorDiv": guard rhs != 0 else { throw ResolutionError(message: "Division by zero in Cura settings.") }; return .number(floor(lhs / rhs))
                case "Mod": guard rhs != 0 else { throw ResolutionError(message: "Division by zero in Cura settings.") }; return .number(lhs - floor(lhs / rhs) * rhs)
                case "Pow": return .number(pow(lhs, rhs))
                default: throw ResolutionError(message: "Unsupported arithmetic Cura expression.")
                }
            case "compare":
                var left = try evaluate(arguments[0])
                for (index, operation) in (node.ops ?? []).enumerated() {
                    let right = try evaluate(arguments[index + 1])
                    var matches: Bool
                    switch operation {
                    case "Eq": matches = left == right
                    case "NotEq": matches = left != right
                    case "In": matches = try right.list().contains(left)
                    case "NotIn": matches = try !right.list().contains(left)
                    case "Lt": matches = try left.numeric() < right.numeric()
                    case "LtE": matches = try left.numeric() <= right.numeric()
                    case "Gt": matches = try left.numeric() > right.numeric()
                    case "GtE": matches = try left.numeric() >= right.numeric()
                    default: throw ResolutionError(message: "Unsupported comparison in Cura settings.")
                    }
                    if !matches { return .bool(false) }
                    left = right
                }
                return .bool(true)
            case "call": return try call(node.name ?? "", arguments.map(evaluate))
            default: throw ResolutionError(message: "Unsupported Cura expression kind: \(node.kind).")
            }
        }

        func call(_ name: String, _ args: [Value]) throws -> Value {
            switch name {
            case "resolveOrValue": return try get(args[0].text())
            case "extruderValue": return try get(args[1].text())
            case "extruderValues": return .array([try get(args[0].text())])
            case "defaultExtruderPosition": return .number(0)
            case "anyExtruderWithMaterial": return .bool(try get(args[0].text()).truth)
            case "min", "max":
                let values = args.count == 1 && { if case .array = args[0] { return true }; return false }() ? try args[0].list() : args
                let numbers = try values.map { try $0.numeric() }
                guard let result = name == "min" ? numbers.min() : numbers.max() else { throw ResolutionError(message: "An empty list was used in a Cura setting.") }
                return .number(result)
            case "round":
                let value = try args[0].numeric(), digits = args.count > 1 ? try args[1].numeric() : 0
                let scale = pow(10, digits)
                return .number((value * scale).rounded(.toNearestOrEven) / scale)
            case "int": return .number(try args[0].numeric().rounded(.towardZero))
            case "float": return .number(try args[0].numeric())
            case "abs": return .number(try abs(args[0].numeric()))
            case "sum": return .number(try args[0].list().reduce(0) { try $0 + $1.numeric() })
            case "len": return .number(Double(try args[0].list().count))
            case "any": return .bool(try args[0].list().contains(where: \.truth))
            case "all": return .bool(try args[0].list().allSatisfy(\.truth))
            case "map":
                guard case .function(let function) = args[0], function == "abs" else { throw ResolutionError(message: "Unsupported mapped Cura function.") }
                return .array(try args[1].list().map { .number(try abs($0.numeric())) })
            case "math.ceil": return .number(try ceil(args[0].numeric()))
            case "math.floor": return .number(try floor(args[0].numeric()))
            case "math.radians": return .number(try args[0].numeric() * .pi / 180)
            case "math.tan": return .number(try tan(args[0].numeric()))
            case "math.sqrt": return .number(try sqrt(args[0].numeric()))
            default: throw ResolutionError(message: "Unsupported Cura function: \(name).")
            }
        }
    }
}
