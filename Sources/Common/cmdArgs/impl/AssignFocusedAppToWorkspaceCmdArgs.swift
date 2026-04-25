public struct AssignFocusedAppToWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public static let parser: CmdParser<Self> = .init(
        kind: .assignFocusedAppToWorkspace,
        allowInConfig: true,
        help: assign_focused_app_to_workspace_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.workspace, parseAssignWorkspaceName, placeholder: "<workspace-name>")],
    )

    public var workspace: Lateinit<WorkspaceName> = .uninitialized

    public init(rawArgs: StrArrSlice) {
        self.commonState = .init(rawArgs)
    }
}

private func parseAssignWorkspaceName(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceName> {
    .init(WorkspaceName.parse(i.arg), advanceBy: 1)
}
