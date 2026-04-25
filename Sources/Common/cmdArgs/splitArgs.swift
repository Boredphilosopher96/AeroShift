extension String {
    // Input: "  foo   bar ". Output: ["foo", "bar"]
    // Input "foo 'bar baz'". Output ["foo", "bar baz"]
    public func splitArgs() -> Parsed<[String]> {
        var result: [String] = []
        var arg: String = ""
        var state: State = .parseArgWhitespaceSeparator
        for char in self {
            switch state { // State machine
                case .parseArgWhitespaceSeparator:
                    if char == "\"" || char == "\'" {
                        state = .parseArg(quoteChar: char, escaping: false)
                    } else if !char.isWhitespace {
                        state = .parseArg(quoteChar: nil, escaping: false)
                        arg.append(char)
                    }
                case .parseArg(nil, _) where char.isWhitespace:
                    result.append(arg)
                    state = .parseArgWhitespaceSeparator
                    arg = ""
                case .parseArg(nil, _) where char.isQuote:
                    return .failure("Unexpected quote \(char) in argument '\(arg)'")
                case .parseArg(let quoteChar?, true):
                    if char == quoteChar || char == "\\" {
                        arg.append(char)
                    } else {
                        arg.append("\\")
                        arg.append(char)
                    }
                    state = .parseArg(quoteChar: quoteChar, escaping: false)
                case .parseArg(let quoteChar?, false) where char == "\\":
                    state = .parseArg(quoteChar: quoteChar, escaping: true)
                case .parseArg(let quoteChar?, false) where char == quoteChar:
                    result.append(arg)
                    arg = ""
                    state = .parseArgWhitespaceSeparator
                case .parseArg(let quoteChar, let escaping):
                    arg.append(char)
                    state = .parseArg(quoteChar: quoteChar, escaping: escaping)
            }
        }
        if case .parseArg(let quoteChar, _) = state {
            if let quoteChar {
                return .failure("Last quote \(quoteChar) isn't closed")
            } else {
                result.append(arg)
            }
        }
        return .success(result)
    }
}

extension Character {
    fileprivate var isQuote: Bool { self == "\'" || self == "\"" }
}

private enum State {
    case parseArg(quoteChar: Character?, escaping: Bool)
    case parseArgWhitespaceSeparator
}

extension [String] {
    public func joinArgs() -> String {
        self.map {
            let containsWhitespaces = $0.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            let containsDoubleQuote = $0.contains("\"")
            let containsBackslash = $0.contains("\\")
            return switch true {
                case containsWhitespaces || containsDoubleQuote || containsBackslash:
                    $0.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"").quoted(with: "\"")
                default:
                    $0
            }
        }.joined(separator: " ")
    }
}
