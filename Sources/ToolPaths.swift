import Foundation

/// Every file location an adapter may touch. Injected so tests never read or
/// write a real user config.
struct ToolPaths {
    var piSettings: String = ""
    var piAuth: String = ""
    var piModels: String = ""
    var piModelsStore: String = ""
    var opencodeConfig: String = ""
    var opencodeAuth: String = ""
    var hermesConfig: String = ""
    var hermesEnv: String = ""
    var clawdbotConfig: String = ""
    var clawdbotDir: String = ""
    var clawdbotBin: String = ""

    /// The real user paths, from the design spec's tool table.
    static var real: ToolPaths {
        let home = NSHomeDirectory()
        var paths = ToolPaths()
        paths.piSettings = "\(home)/.pi/agent/settings.json"
        paths.piAuth = "\(home)/.pi/agent/auth.json"
        paths.piModels = "\(home)/.pi/agent/models.json"
        paths.piModelsStore = "\(home)/.pi/agent/models-store.json"
        paths.opencodeConfig = "\(home)/.config/opencode/opencode.json"
        paths.opencodeAuth = "\(home)/.local/share/opencode/auth.json"
        paths.hermesConfig = "\(home)/.hermes/config.yaml"
        paths.hermesEnv = "\(home)/.hermes/.env"
        paths.clawdbotConfig = "\(home)/.clawdbot/clawdbot.json"
        paths.clawdbotDir = "\(home)/.clawdbot"
        paths.clawdbotBin = resolveBinary("clawdbot")
        return paths
    }

    /// Copies the fixture directory's contents into a fresh temp directory and
    /// returns paths pointing at the copies. No path outside the temp directory
    /// is written. A missing fixture maps to a path that does not exist.
    func stagedInTempDir(from fixtures: String) throws -> ToolPaths {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ProviderCostController-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        if let entries = try? fm.contentsOfDirectory(atPath: fixtures) {
            for entry in entries {
                try fm.copyItem(atPath: "\(fixtures)/\(entry)", toPath: "\(root)/\(entry)")
            }
        }

        var paths = ToolPaths()
        paths.piSettings = "\(root)/pi-settings.json"
        paths.piAuth = "\(root)/pi-auth.json"
        paths.piModels = "\(root)/pi-models.json"
        paths.piModelsStore = "\(root)/pi-models-store.json"
        paths.opencodeConfig = "\(root)/opencode.json"
        paths.opencodeAuth = "\(root)/opencode-auth.json"
        paths.hermesConfig = "\(root)/hermes-config.yaml"
        paths.hermesEnv = "\(root)/hermes.env"
        paths.clawdbotConfig = "\(root)/clawdbot.json"
        paths.clawdbotDir = root
        paths.clawdbotBin = "\(root)/bin/clawdbot"

        if fm.fileExists(atPath: paths.clawdbotBin) {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clawdbotBin)
        }
        return paths
    }

    private static func resolveBinary(_ name: String) -> String {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }
}
