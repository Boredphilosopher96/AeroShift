import Common

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        TreeTopology.shared.rootTilingContainer(
            for: self,
            defaultOrientation: {
                switch config.defaultRootContainerOrientation {
                    case .horizontal: .h
                    case .vertical: .v
                    case .auto: workspaceMonitor.then { $0.width >= $0.height } ? .h : .v
                }
            },
            defaultLayout: { config.defaultRootContainerLayout },
        )
    }

    var floatingWindows: [Window] {
        TreeTopology.shared.floatingWindows(in: self)
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        TreeTopology.shared.singletonChildContainer(
            in: self,
            of: MacosFullscreenWindowsContainer.self,
            create: { MacosFullscreenWindowsContainer(parent: self) },
            errorMessage: "Workspace must contain zero or one MacosFullscreenWindowsContainer",
        )
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        TreeTopology.shared.singletonChildContainer(
            in: self,
            of: MacosHiddenAppsWindowsContainer.self,
            create: { MacosHiddenAppsWindowsContainer(parent: self) },
            errorMessage: "Workspace must contain zero or one MacosHiddenAppsWindowsContainer",
        )
    }

    @MainActor var forceAssignedMonitor: Monitor? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = sortedMonitors
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
            .first
    }
}
