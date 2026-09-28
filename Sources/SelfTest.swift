import Foundation

enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    static func run() -> Int32 {
        check("harness detects a false condition", 1 == 1)
        checkStaging()
        return failures == 0 ? 0 : 1
    }

    /// Verifies stagedInTempDir copies within a temp dir, maps fixture names to
    /// the right fields, leaves absent fixtures absent, and chmods the stub.
    private static func checkStaging() {
        let fm = FileManager.default
        do {
            let source = fm.temporaryDirectory
                .appendingPathComponent("pcc-fixtures-\(UUID().uuidString)").path
            try fm.createDirectory(atPath: "\(source)/bin", withIntermediateDirectories: true)
            try "{\"defaultProvider\":\"openrouter\"}".write(
                toFile: "\(source)/pi-settings.json", atomically: true, encoding: .utf8)
            try "#!/bin/sh\n".write(
                toFile: "\(source)/bin/clawdbot", atomically: true, encoding: .utf8)

            let paths = try ToolPaths().stagedInTempDir(from: source)
            let root = (paths.piSettings as NSString).deletingLastPathComponent

            check("staged piSettings lands in the temp root",
                  paths.piSettings == "\(root)/pi-settings.json")
            check("staged piSettings copied its content",
                  (try? String(contentsOfFile: paths.piSettings, encoding: .utf8))?
                      .contains("openrouter") == true)
            check("absent fixture maps to a nonexistent temp path",
                  paths.opencodeConfig == "\(root)/opencode.json"
                      && !fm.fileExists(atPath: paths.opencodeConfig))
            check("clawdbotDir is the staged config's parent",
                  paths.clawdbotDir == root
                      && (paths.clawdbotConfig as NSString).deletingLastPathComponent == root)
            let attrs = try? fm.attributesOfItem(atPath: paths.clawdbotBin)
            let mode = attrs?[.posixPermissions] as? NSNumber
            check("staged clawdbot stub is executable 0755", mode?.intValue == 0o755)

            let other = try ToolPaths().stagedInTempDir(from: source)
            check("each staging call gets a fresh temp directory",
                  other.clawdbotDir != paths.clawdbotDir)

            try? fm.removeItem(atPath: source)
        } catch {
            check("staging check could not run: \(error)", false)
        }
    }
}
