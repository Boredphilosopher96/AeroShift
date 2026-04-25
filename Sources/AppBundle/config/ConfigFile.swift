import Common
import Foundation

let configDotfileName = ".aeroshift.toml"
let legacyAerospaceConfigDotfileName = ".aerospace.toml"

func findCustomConfigUrl() -> ConfigFile {
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
    return resolveCustomConfigUrl(
        explicitConfigLocation: serverArgs.configLocation,
        home: FileManager.default.homeDirectoryForCurrentUser,
        xdgConfigHome: xdgConfigHome,
    ) { candidate in
        FileManager.default.fileExists(atPath: candidate.path)
    }
}

func resolveCustomConfigUrl(
    explicitConfigLocation: String?,
    home: URL,
    xdgConfigHome: URL,
    fileExists: (URL) -> Bool,
) -> ConfigFile {
    if let explicitConfigLocation {
        return .file(URL(filePath: explicitConfigLocation))
    }

    let aeroshiftCandidates = [
        home.appending(path: configDotfileName),
        xdgConfigHome.appending(path: "aeroshift").appending(path: "aeroshift.toml"),
    ].filter(fileExists)

    if !aeroshiftCandidates.isEmpty {
        return aeroshiftCandidates.singleOrNil().map(ConfigFile.file) ?? .ambiguousConfigError(aeroshiftCandidates)
    }

    let aerospaceCandidates = [
        home.appending(path: legacyAerospaceConfigDotfileName),
        xdgConfigHome.appending(path: "aerospace").appending(path: "aerospace.toml"),
    ].filter(fileExists)

    if !aerospaceCandidates.isEmpty {
        return aerospaceCandidates.singleOrNil().map(ConfigFile.file) ?? .ambiguousConfigError(aerospaceCandidates)
    }

    return .noCustomConfigExists
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
