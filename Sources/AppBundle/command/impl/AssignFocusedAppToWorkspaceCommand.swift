import Common
import Foundation

struct AssignFocusedAppToWorkspaceCommand: Command {
    let args: AssignFocusedAppToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        if serverArgs.isReadOnly {
            return .fail(io.err("Cannot assign focused app to workspace while Aeroshift is running in read-only mode"))
        }

        guard let window = focus.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        guard let appId = window.app.rawAppBundleId, !appId.isEmpty else {
            return .fail(io.err("Focused app doesn't have a bundle id and cannot be assigned to a workspace"))
        }

        let workspaceName = args.workspace.val.raw
        let configFileUrl: URL
        switch prepareWritableConfigFile() {
            case .success(let url): configFileUrl = url
            case .failure(let message): return .fail(io.err(message))
        }

        let rawConfig: String
        do {
            rawConfig = try String(contentsOf: configFileUrl, encoding: .utf8)
        } catch {
            return .fail(io.err("Failed to read config \(configFileUrl.path): \(error.localizedDescription)"))
        }

        let originalParse = parseConfig(rawConfig)
        if !originalParse.errors.isEmpty {
            return .fail(io.err("Refusing to update invalid config \(configFileUrl.path):\n\(originalParse.errors.joined(separator: "\n"))"))
        }

        let updatedConfig = assignAppToWorkspaceInConfig(rawConfig, appId: appId, workspaceName: workspaceName)
        let updatedParse = parseConfig(updatedConfig)
        if !updatedParse.errors.isEmpty {
            return .fail(io.err("Refusing to write generated config because it does not parse:\n\(updatedParse.errors.joined(separator: "\n"))"))
        }

        do {
            try updatedConfig.write(to: configFileUrl, atomically: true, encoding: .utf8)
        } catch {
            return .fail(io.err("Failed to write config \(configFileUrl.path): \(error.localizedDescription)"))
        }

        var reloadOutput = ""
        if try await !reloadConfig(forceConfigUrl: configFileUrl, stdout: &reloadOutput) {
            return .fail(io.err(reloadOutput))
        }

        let targetWorkspace = Workspace.get(byName: workspaceName)
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: false, failIfNoop: false)
    }
}

@MainActor
private func prepareWritableConfigFile() -> Result<URL, String> {
    if configUrl.standardizedFileURL != defaultConfigUrl.standardizedFileURL {
        return .success(configUrl)
    }

    let fallbackConfig = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
    if FileManager.default.fileExists(atPath: fallbackConfig.path) {
        return .success(fallbackConfig)
    }

    do {
        try FileManager.default.copyItem(at: defaultConfigUrl, to: fallbackConfig)
        return .success(fallbackConfig)
    } catch {
        return .failure("Failed to create \(fallbackConfig.path) from the default config: \(error.localizedDescription)")
    }
}
