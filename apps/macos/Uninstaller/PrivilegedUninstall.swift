// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
enum PrivilegedUninstall {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result: UninstallResult
        var code: Int32 = 1
        if arguments.count != 1 || UninstallMode(rawValue: arguments[0]) == nil {
            result = UninstallResult(message: "仅接受 --preflight 或 --uninstall；不接受路径、环境覆盖或其他参数。", phase: "arguments")
            code = 64
        } else {
            let mode = UninstallMode(rawValue: arguments[0])!
            let coordinator = UninstallCoordinator(files: SafeUninstallFileSystem.production(),
                audio: CoreAudioUninstallChecks(), processes: NativeUninstallProcessChecks(), receipts: PkgutilUninstallReceipts())
            result = coordinator.run(mode: mode, effectiveUID: geteuid())
            code = result.success ? 0 : (mode == .uninstall && geteuid() != 0 ? 77 : 1)
        }
        // Exactly one JSON object on stdout. Adapters never write to stdout.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } else {
            FileHandle.standardOutput.write(Data("{\"success\":false,\"restartRequired\":true,\"message\":\"无法编码卸载结果，操作可能部分完成。\"}\n".utf8))
            code = 1
        }
        exit(code)
    }
}
