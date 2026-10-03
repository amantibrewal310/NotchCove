import AppKit

/// Coding agent that shelf items are handed to (menu bar → Agent).
enum CodingAgent: String, Setting {
    case claudeCode, codex, pi, openCode

    static let defaultsKey = "CodingAgent"
    static let defaultValue = CodingAgent.claudeCode

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .openCode: "OpenCode"
        }
    }

    /// Short name for the shelf card.
    var shortTitle: String {
        switch self {
        case .claudeCode: "Claude"
        default: title
        }
    }

    /// Shell command that starts an interactive session, with the prompt read
    /// from `$NOTCHCOVE_PROMPT` when there is one.
    func command(withPrompt: Bool) -> String {
        let (binary, promptFlag) = switch self {
        case .claudeCode: ("claude", "")
        case .codex: ("codex", "")
        case .pi: ("pi", "")
        case .openCode: ("opencode", "--prompt ")
        }
        return withPrompt ? "\(binary) \(promptFlag)\"$NOTCHCOVE_PROMPT\"" : binary
    }
}

/// Terminal app the agent runs in (menu bar → Agent Terminal). Only installed
/// ones are offered.
enum TerminalApp: String, Setting {
    case ghostty, iTerm, terminal, wezTerm, kitty, alacritty

    static let defaultsKey = "AgentTerminal"
    /// A third-party terminal someone installed is likely the one they use.
    static var defaultValue: TerminalApp { allCases.first(where: \.isInstalled) ?? .terminal }

    var title: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm"
        case .terminal: "Terminal"
        case .wezTerm: "WezTerm"
        case .kitty: "kitty"
        case .alacritty: "Alacritty"
        }
    }

    private var bundleId: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .iTerm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        case .wezTerm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
    var isInstalled: Bool { appURL != nil }

    /// Runs `script` in a new window. Ghostty, iTerm and Terminal open scripts
    /// like documents; the others take the command as launch arguments, and
    /// WezTerm and kitty hand it to their running instance.
    func run(script: URL, in directory: URL) {
        guard let appURL else { return NSSound.beep() }
        let config = NSWorkspace.OpenConfiguration()
        switch self {
        case .ghostty, .iTerm, .terminal:
            NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: config)
            return
        case .wezTerm:
            config.arguments = ["start", "--cwd", directory.path, "--", script.path]
        case .kitty:
            config.arguments = ["--single-instance", "--directory", directory.path, script.path]
        case .alacritty:
            config.arguments = ["--working-directory", directory.path, "-e", script.path]
        }
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
}

/// Opens the chosen coding agent in a terminal with shelf items as context.
/// Starts the user's own CLI: no API keys, no network, no Automation prompt.
@MainActor
enum AgentHandoff {
    static func handOff(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let agent = CodingAgent.current
        let fileURLs = urls.filter(\.isFileURL)
        let directory = workingDirectory(for: fileURLs)

        // A lone folder is a project to work in, not something to read.
        let isProject = urls.count == 1 && fileURLs.first.map(isDirectory) == true
        let prompt = isProject ? nil : self.prompt(for: urls)

        do {
            let script = try writeScript(agent: agent, prompt: prompt, directory: directory)
            TerminalApp.current.run(script: script, in: directory)
        } catch {
            clog("[Agent] \(error)")
            NSSound.beep()
        }
    }

    private static func prompt(for urls: [URL]) -> String {
        let list = urls.map { "- " + ($0.isFileURL ? $0.path : $0.absoluteString) }.joined(separator: "\n")
        return "I've shared these from NotchCove. Read them, then ask me what I'd like to do:\n\n\(list)"
    }

    /// Deepest folder holding every item (a folder counts as itself), or home
    /// when that would be the disk root or /Users.
    private static func workingDirectory(for urls: [URL]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = urls.map { isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
        guard var common = dirs.first?.standardizedFileURL.pathComponents else { return home }
        for dir in dirs.dropFirst() {
            let parts = dir.standardizedFileURL.pathComponents
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 2 else { return home }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// A self-deleting script that runs the agent through the user's login
    /// shell (so PATH from nvm, Homebrew etc. applies), then leaves that shell
    /// open. The prompt travels in an environment variable, so no quoting
    /// differs between zsh, bash and fish.
    private static func writeScript(agent: CodingAgent, prompt: String?, directory: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchCove", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("agent-\(UUID().uuidString.prefix(8)).command")

        var lines = [
            "#!/bin/zsh",
            "rm -f \"$0\"",
            "cd \(shellQuoted(directory.path)) || exit 1",
        ]
        if let prompt { lines.append("export NOTCHCOVE_PROMPT=\(shellQuoted(prompt))") }
        let run = "\(agent.command(withPrompt: prompt != nil)); exec $SHELL -l"
        lines.append("exec \"${SHELL:-/bin/zsh}\" -lic \(shellQuoted(run))")

        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
