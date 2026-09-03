// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AudioServiceMode: String { case preflight = "--preflight", reload = "--reload" }

struct AudioServiceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AudioServiceResult: Codable {
    var success = false
    var requestSent = false
    var message: String
    var phase: String
    var diagnostic: AudioServiceDiagnostic?
}

/// Only the fixed system daemon's identity and bounded numeric outcome are
/// returned. Never include environment, full process lists, or arbitrary output.
struct AudioServiceDiagnostic: Codable, Equatable {
    var method = "posix_sigterm"
    var targetPID: Int32?
    var targetUID: UInt32?
    var targetStartSeconds: UInt64?
    var targetStartMicroseconds: UInt64?
    var returnCode: Int32?
    var errorNumber: Int32?
    var afterCheck: String?
}
enum AudioServiceDispatchOutcome {
    case sent(AudioServiceDiagnostic)
    case rejected(String, AudioServiceDiagnostic)
    case unknown(String, AudioServiceDiagnostic)
}

protocol AudioServiceInstallationChecking { func checkInstalled() throws }
protocol AudioServiceProcessChecking { func checkNoConflict() throws }
protocol AudioServiceRequestSending { func sendReloadRequest() throws -> AudioServiceDispatchOutcome }
enum AudioServiceReadiness { case ready, reloadRequired }
protocol AudioServiceReadinessChecking { func state() throws -> AudioServiceReadiness }

final class AudioServiceCoordinator {
    private let installation: AudioServiceInstallationChecking
    private let processes: AudioServiceProcessChecking
    private let sender: AudioServiceRequestSending
    private let readiness: AudioServiceReadinessChecking
    private var attempted = false
    init(installation: AudioServiceInstallationChecking, processes: AudioServiceProcessChecking,
         sender: AudioServiceRequestSending, readiness: AudioServiceReadinessChecking) {
        self.installation = installation; self.processes = processes; self.sender = sender; self.readiness = readiness
    }

    func run(mode: AudioServiceMode, effectiveUID: UInt32) -> AudioServiceResult {
        var result = AudioServiceResult(message: "", phase: "preflight")
        if mode == .reload && effectiveUID != 0 {
            result.message = "重载音频服务需要管理员授权；未发送请求。"
            return result
        }
        if mode == .reload && attempted {
            result.phase = "already-attempted"
            result.message = "本次操作已尝试发送请求，不会重复发送。请先检查系统音频状态。"
            return result
        }
        do {
            try processes.checkNoConflict()
            try installation.checkInstalled()
            if mode == .preflight {
                result.success = true
                result.message = "安装身份与并发状态预检查通过；未发送请求，未更改音频设置。"
                return result
            }
            // A preflight in another process is never treated as authorization
            // to skip the root checks immediately before this one request.
            result.phase = "recheck"
            try processes.checkNoConflict()
            try installation.checkInstalled()
            result.phase = "readiness"
            if try readiness.state() == .ready {
                result.success = true
                result.phase = "already_ready"
                result.message = "专用音频两端已通过完整校验，无需重新加载；未发送重载请求。程序将再次确认状态。"
                return result
            }
            result.phase = "request"
            attempted = true
            switch try sender.sendReloadRequest() {
            case .sent(let diagnostic):
                result.success = true
                result.requestSent = true
                result.phase = "request-sent"
                result.diagnostic = diagnostic
                result.message = "已向核验后的系统音频进程发送一次重载信号。系统音频可能短暂中断；尚未确认遥控器麦克风可用，请等待程序回读结果。"
            case .rejected(let message, let diagnostic):
                result.phase = "request_rejected"
                result.diagnostic = diagnostic
                result.message = "本次重载请求被明确拒绝，未发送信号；没有后台重载任务需要等待。" + message
            case .unknown(let message, let diagnostic):
                result.phase = "request_unknown"
                result.diagnostic = diagnostic
                result.message = "重载请求结果无法确认，不会自动重试。" + message
            }
        } catch {
            if attempted { result.phase = "request_unknown" }
            result.message = (attempted ? "重载请求未确认成功，不会自动重试。" : "检查未通过，未发送重载请求。") + error.localizedDescription
        }
        return result
    }
}
