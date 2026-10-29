import Foundation

private struct Fixture: Decodable {
    let name: String
    let snapshot: [String: String]
    let expressions: [String: String]
    let overrides: [String: String]
    let literalKeys: [String]
    let expected: [String: String]
}

@main
private struct SettingsResolverCheck {
    static func main() throws {
        let arguments = CommandLine.arguments
        try NativeSettingsResolver.registerExpressionTrees(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        var comparisons = 0
        for fixture in fixtures {
            let actual = try NativeSettingsResolver.resolve(snapshot: fixture.snapshot, expressions: fixture.expressions, overrides: fixture.overrides, literalKeys: Set(fixture.literalKeys))
            for (key, expected) in fixture.expected {
                guard let observed = actual[key] else { throw NativeSettingsResolver.ResolutionError(message: "\(fixture.name): missing \(key)") }
                let equivalent: Bool
                if let lhs = Double(observed), let rhs = Double(expected) {
                    equivalent = abs(lhs - rhs) <= 1e-9 * max(1, abs(rhs))
                } else if observed.hasPrefix("["), expected.hasPrefix("["),
                          let left = try? JSONSerialization.jsonObject(with: Data(observed.utf8)),
                          let right = try? JSONSerialization.jsonObject(with: Data(expected.utf8)),
                          let leftObject = left as? NSObject, let rightObject = right as? NSObject {
                    equivalent = leftObject.isEqual(rightObject)
                } else { equivalent = observed == expected }
                guard equivalent else {
                    throw NativeSettingsResolver.ResolutionError(message: "\(fixture.name): \(key) = \(observed), expected \(expected)")
                }
                comparisons += 1
            }
            if fixture.overrides.isEmpty, actual != fixture.snapshot {
                throw NativeSettingsResolver.ResolutionError(message: "An unchanged snapshot was modified.")
            }
            print("PASS \(fixture.name)")
        }
        print("PASS \(fixtures.count) cases, \(comparisons) setting comparisons")
    }
}
