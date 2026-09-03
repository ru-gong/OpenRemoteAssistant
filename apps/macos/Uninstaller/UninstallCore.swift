// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum UninstallTarget: String, Codable, CaseIterable {
    case driver
    case hidService = "hid-service"
    case application

    var leaf: String {
        switch self {
        case .driver: return "OpenRemoteAudio.driver"
        case .hidService: return "OpenRemoteHIDCoreService.app"
        case .application: return "遥控器助手.app"
        }
    }
    var bundleID: String {
        switch self {
        case .driver: return "org.rc001remote.audio"
        case .hidService: return "org.rc001remote.assistant.hid-core-service"
        case .application: return "org.rc001remote.assistant"
        }
    }
    var path: String {
        switch self {
        case .driver: return "/Library/Audio/Plug-Ins/HAL/\(leaf)"
        case .hidService: return "/Library/PrivilegedHelperTools/\(leaf)"
        case .application: return "/Applications/\(leaf)"
        }
    }
}

enum UninstallMode: String { case preflight = "--preflight", uninstall = "--uninstall" }

struct UninstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

protocol UninstallAudioChecking { func checkSafe() throws }
protocol UninstallProcessChecking { func checkStopped() throws }
protocol UninstallReceiptManaging {
    func installed() throws -> Set<String>
    func forget(_ identifier: String) throws
}
protocol UninstallFileManaging {
    var mutationOccurred: Bool { get }
    var recoveryPaths: [String] { get }
    func prepare() throws -> Set<UninstallTarget>
    func remove(_ target: UninstallTarget) throws
    func verifyAbsent() throws
    func finish() throws
}

struct UninstallResult: Codable {
    var success = false
    var restartRequired = false
    var message: String
    var phase: String
    var possiblePartialCompletion = false
    var removedTargets: [String] = []
    var alreadyAbsentTargets: [String] = []
    var receiptsBefore: [String] = []
    var forgottenReceipts: [String] = []
    var recoveryPaths: [String] = []
}

final class UninstallCoordinator {
    static let receiptIDs: Set<String> = ["org.rc001remote.assistant.pkg", "org.rc001remote.assistant.pkg.uninstall"]
    private let files: UninstallFileManaging
    private let audio: UninstallAudioChecking
    private let processes: UninstallProcessChecking
    private let receipts: UninstallReceiptManaging
    init(files: UninstallFileManaging, audio: UninstallAudioChecking,
         processes: UninstallProcessChecking, receipts: UninstallReceiptManaging) {
        self.files = files; self.audio = audio; self.processes = processes; self.receipts = receipts
    }
    func run(mode: UninstallMode, effectiveUID: UInt32) -> UninstallResult {
        var result = UninstallResult(message: "", phase: "preflight")
        var receiptMutationAttempted = false
        if mode == .uninstall && effectiveUID != 0 {
            result.message = "卸载必须由管理员授权后以 root 运行；未执行删除。"
            return result
        }
        do {
            try processes.checkStopped()
            try audio.checkSafe()
            let present = try files.prepare()
            result.alreadyAbsentTargets = UninstallTarget.allCases.filter { !present.contains($0) }.map(\.path)
            let initialReceipts = try receipts.installed()
            guard initialReceipts.isSubset(of: Self.receiptIDs) else { throw UninstallFailure("收据查询返回了非本产品标识。") }
            result.receiptsBefore = initialReceipts.sorted()
            if mode == .preflight {
                result.success = true
                result.message = "预检查通过；尚未删除文件或收据。实际卸载会重新检查占用与身份。"
                return result
            }
            // Recheck all external conditions before each component. No process
            // is killed and no audio default is changed, including on failure.
            for target in [UninstallTarget.driver, .hidService, .application] where present.contains(target) {
                result.phase = "remove-\(target.rawValue)"
                try processes.checkStopped()
                try audio.checkSafe()
                try files.remove(target)
                result.removedTargets.append(target.path)
            }
            result.phase = "verify-files"
            try files.verifyAbsent()
            try files.finish()
            result.phase = "receipts"
            for identifier in initialReceipts.sorted() {
                receiptMutationAttempted = true
                try receipts.forget(identifier)
                result.forgottenReceipts.append(identifier)
            }
            guard try receipts.installed().isEmpty else { throw UninstallFailure("卸载收据仍然存在；没有将失败标记为完成。") }
            // A concurrent reinstall is reported, never silently removed.
            try files.verifyAbsent()
            result.success = true
            result.phase = "complete"
            result.restartRequired = files.mutationOccurred || !result.forgottenReceipts.isEmpty
            result.message = result.restartRequired
                ? "已移除本产品应用、遥控器按键服务、专用音频驱动和现有收据；个人配置未触碰。请重启 Mac 使驱动卸载生效。"
                : "本产品应用、遥控器按键服务、音频驱动及收据均已不存在；个人配置未触碰。"
        } catch {
            let failure = error.localizedDescription
            var cleanupFailure: String?
            if mode == .uninstall {
                do { try files.finish() }
                catch { cleanupFailure = error.localizedDescription }
            }
            result.possiblePartialCompletion = files.mutationOccurred || receiptMutationAttempted || !files.recoveryPaths.isEmpty
            result.restartRequired = result.possiblePartialCompletion
            result.recoveryPaths = files.recoveryPaths
            result.message = (result.possiblePartialCompletion ? "卸载未完成，可能已经部分完成。" : "检查未通过，未执行删除。")
                + failure
            if let cleanupFailure { result.message += " 清理结果：" + cleanupFailure }
            if !result.recoveryPaths.isEmpty { result.message += " 隔离内容保留在：" + result.recoveryPaths.joined(separator: "；") + "。未扩大删除范围。" }
        }
        return result
    }
}
