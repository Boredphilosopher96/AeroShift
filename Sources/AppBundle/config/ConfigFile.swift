import Common
import Foundation

let configDotfileName = ".aeroshift.toml"
let legacyAerospaceConfigDotfileName = ".aerospace.toml"

func findCustomConfigUrl() -> ConfigFile {
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
    let home = FileManager.default.homeDirectoryForCurrentUser
    return resolveCustomConfigUrl(
        explicitConfigLocation: serverArgs.configLocation,
        home: home,
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
        initialAeroshiftConfigUrl(home: home),
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

    return .noCustomConfigExists(initialAeroshiftConfigUrl(home: home))
}

func initialAeroshiftConfigUrl(home: URL) -> URL {
    home.appending(path: ".config").appending(path: configDotfileName)
}

func createInitialConfigFile(at target: URL, from source: URL = defaultConfigUrl) -> Result<Void, String> {
    let fm = FileManager.default
    if fm.fileExists(atPath: target.path) {
        return .success(())
    }

    do {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
        return .success(())
    } catch {
        if fm.fileExists(atPath: target.path) {
            return .success(())
        }
        return .failure("Failed to create initial config at \(target.path.singleQuoted): \(error.localizedDescription)")
    }
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists(_ initialConfigUrl: URL)

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
