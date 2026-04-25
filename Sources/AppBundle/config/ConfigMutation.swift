import Common
import Foundation

func assignAppToWorkspaceInConfig(_ rawConfig: String, appId: String, workspaceName: String) -> String {
    let lines = rawConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let blockStarts = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "[[on-window-detected]]" }
    for (offset, start) in blockStarts.enumerated() {
        let end = offset + 1 < blockStarts.count ? blockStarts[offset + 1] : lines.endIndex
        if let runLine = simpleAppAssignmentRunLine(in: lines, start: start, end: end, appId: appId) {
            var updatedLines = lines
            let indent = String(updatedLines[runLine].prefix { $0 == " " || $0 == "\t" })
            updatedLines[runLine] = "\(indent)run = \(tomlString(appAssignmentCommand(workspaceName)))"
            return updatedLines.joined(separator: "\n")
        }
    }

    return appendAppAssignmentBlock(rawConfig, appId: appId, workspaceName: workspaceName)
}

private func simpleAppAssignmentRunLine(in lines: [String], start: Int, end: Int, appId: String) -> Int? {
    var keys: Set<String> = []
    var matchedApp = false
    var runLine: Int?

    for index in start + 1 ..< end {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.starts(with: "#") {
            continue
        }
        guard let equalIndex = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[..<equalIndex].trimmingCharacters(in: .whitespaces)
        keys.insert(String(key))
        let rawValue = line[line.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
        switch key {
            case "if.app-id":
                matchedApp = parseTomlStringPrefix(String(rawValue)) == appId
            case "run":
                guard let command = parseTomlStringPrefix(String(rawValue)),
                      let moveCommand = parseCommand(command).cmdOrNil as? MoveNodeToWorkspaceCommand,
                      moveCommand.args.target.val.workspaceNameOrNil() != nil
                else {
                    return nil
                }
                runLine = index
            default:
                return nil
        }
    }

    return matchedApp && keys == ["if.app-id", "run"] ? runLine : nil
}

private func appendAppAssignmentBlock(_ rawConfig: String, appId: String, workspaceName: String) -> String {
    let separator: String = if rawConfig.isEmpty {
        ""
    } else if rawConfig.hasSuffix("\n\n") {
        ""
    } else if rawConfig.hasSuffix("\n") {
        "\n"
    } else {
        "\n\n"
    }

    return rawConfig + separator + """
        [[on-window-detected]]
            if.app-id = \(tomlString(appId))
            run = \(tomlString(appAssignmentCommand(workspaceName)))
        """
}

private func appAssignmentCommand(_ workspaceName: String) -> String {
    ["move-node-to-workspace", workspaceName].joinArgs()
}

private func parseTomlStringPrefix(_ raw: String) -> String? {
    guard let first = raw.first, first == "'" || first == "\"" else { return nil }
    var result = ""
    var escaped = false
    for char in raw.dropFirst() {
        if first == "'" {
            if char == "'" { return result }
            result.append(char)
            continue
        }

        if escaped {
            switch char {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: return nil
            }
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else if char == "\"" {
            return result
        } else {
            result.append(char)
        }
    }
    return nil
}

private func tomlString(_ value: String) -> String {
    let escaped = value.flatMap { char -> [Character] in
        switch char {
            case "\\": Array("\\\\")
            case "\"": Array("\\\"")
            case "\n": Array("\\n")
            case "\r": Array("\\r")
            case "\t": Array("\\t")
            default: [char]
        }
    }
    return "\"" + String(escaped) + "\""
}
