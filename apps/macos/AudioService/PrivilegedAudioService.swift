// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main enum PrivilegedAudioService {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result: AudioServiceResult
        let code: Int32
        if arguments.count != 1 || AudioServiceMode(rawValue: arguments[0]) == nil {
            result = AudioServiceResult(message: "仅接受 --preflight 或 --reload；不接受路径、服务名称、信号、命令或环境覆盖参数。", phase: "arguments")
            code = 64
        } else {
            let mode = AudioServiceMode(rawValue: arguments[0])!
            let coordinator = AudioServiceCoordinator(installation: AudioServiceInstallation.production(),
                processes: AudioServiceProcesses(), sender: FixedAudioServiceRequest(), readiness: AudioServiceEndpointProbe())
            result = coordinator.run(mode: mode, effectiveUID: geteuid())
            code = result.success ? 0 : (mode == .reload && geteuid() != 0 ? 77 : 1)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(result) else {
            FileHandle.standardOutput.write(Data("{\"success\":false,\"requestSent\":false,\"message\":\"无法编码请求结果；请检查系统状态，不要自动重试。\",\"phase\":\"encoding\"}\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        exit(code)
    }
}
