// SPDX-License-Identifier: GPL-3.0-only
// Pure hostile-protocol/script-construction fixtures plus permission peer
// policy checks. This executable never constructs HIDSessionClient, runs
// Process/script, opens input/socket, authorizes, connects Bluetooth or audio.
import Foundation
import Darwin

@main
enum HIDSessionClientTests {
    static func main() throws {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { failures.append(label) }
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); check(false, label) } catch { check(true, label) }
        }
        let nonce = String(repeating: "a", count: 64)
        let target = HIDClientTarget(registryID: 4_886_718_345, locationID: 436_207_616)
        let allowed: Set<UInt16> = [0x28, 0x4F, 0x50, 0x51, 0x52]
        func decoder() -> HIDClientDecoder { .init(token: nonce, target: target, allowedUsages: allowed) }
        func frame(_ value: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            data.append(10); return data
        }
        func ready(token: String? = nil, registry: UInt64? = nil, location: Int? = nil, version: Int = 1) throws -> Data {
            try frame(["type": "ready", "version": version, "token": token ?? nonce,
                       "registryID": registry ?? target.registryID, "locationID": location ?? target.locationID])
        }
        func keys(_ sequence: UInt64, _ usages: [UInt16]) throws -> Data {
            try frame(["type": "keys", "sequence": sequence, "usages": usages])
        }
        func pong(_ sequence: UInt64) throws -> Data { try frame(["type": "pong", "sequence": sequence]) }
        func rejectBytes(_ bytes: Data, afterReady: Bool = false, lastPing: UInt64 = 0, label: String) throws {
            var d = decoder()
            if afterReady { _ = try d.receive(ready(), lastPing: 0) }
            rejects(label) { _ = try d.receive(bytes, lastPing: lastPing) }
        }
        let handshake = try ready()
        var initial = decoder()
        check(tryResult { try initial.receive(handshake, lastPing: 0) } == [.ready], "ready requires exact valid session and target")
        rejects("second ready cannot reset sequences or reauthenticate") { _ = try initial.receive(handshake, lastPing: 0) }
        for bad in [try ready(token: String(repeating: "b", count: 64)), try ready(token: nonce.uppercased()),
                    try ready(token: ""), try ready(registry: target.registryID + 1), try ready(registry: 0),
                    try ready(location: target.locationID + 1), try ready(location: -1), try ready(version: 0), try ready(version: 2)] {
            try rejectBytes(bad, label: "mismatched ready identity/version rejected")
        }
        try rejectBytes(keys(1, [0x28]), label: "keys before ready rejected")
        try rejectBytes(pong(1), lastPing: 1, label: "pong before ready rejected")
        for extra in ["extra", "usages", "sequence", "reason"] {
            try rejectBytes(frame(["type": "ready", "version": 1, "token": nonce,
                "registryID": target.registryID, "locationID": target.locationID, extra: 0]), label: "ready unknown/cross-frame field rejected")
        }
        for missing in ["version", "token", "registryID", "locationID"] {
            var value: [String: Any] = ["type": "ready", "version": 1, "token": nonce,
                "registryID": target.registryID, "locationID": target.locationID]
            value.removeValue(forKey: missing)
            try rejectBytes(frame(value), label: "ready missing required field rejected")
        }
        for (field, value) in [("version", true as Any), ("token", NSNull()), ("registryID", "4886718345"),
                               ("locationID", "436207616")] {
            var object: [String: Any] = ["type": "ready", "version": 1, "token": nonce,
                "registryID": target.registryID, "locationID": target.locationID]
            object[field] = value
            try rejectBytes(frame(object), label: "ready field type cannot be coerced from bool/null/string")
        }

        // Check every byte split: JSON must not be dispatched before its newline,
        // and a split inside a number/token must not lose handshake identity.
        for split in 1..<handshake.count {
            var d = decoder()
            check(tryResult { try d.receive(Data(handshake.prefix(split)), lastPing: 0) } == [], "partial handshake produces no message")
            check(tryResult { try d.receive(Data(handshake.dropFirst(split)), lastPing: 0) } == [.ready], "reassembled handshake preserves identity")
        }
        do {
            var d = decoder()
            let data = handshake + (try keys(1, [0x28, 0x50, 0x52])) + (try pong(2)) + (try keys(2, []))
            check(tryResult { try d.receive(data, lastPing: 2) } == [.ready, .keys([0x28, 0x50, 0x52]), .pong(2), .keys([])],
                  "coalesced handshake/keys/pong/release preserve wire order")
        }
        do {
            var d = decoder()
            let key = try keys(1, [0x4F])
            let part = key.count / 2
            check(tryResult { try d.receive(handshake + key.prefix(part), lastPing: 0) } == [.ready], "completed frame may precede a partial next frame")
            check(tryResult { try d.receive(Data(key.dropFirst(part)), lastPing: 0) } == [.keys([0x4F])], "partial trailing frame resumes without duplicate dispatch")
        }
        for invalid in [Data("\n".utf8), Data("not json\n".utf8), Data("{}\n".utf8), Data("[]\n".utf8),
                        Data("null\n".utf8), Data("42\n".utf8), Data([0xFF, 0x0A]),
                        Data("{\"type\":\"unknown\"}\n".utf8), Data("{\"type\":\"ready\"}\n".utf8)] {
            try rejectBytes(invalid, label: "malformed/empty/non-object/unknown frame rejected")
        }
        try rejectBytes(Data(repeating: 0x20, count: 4_097), label: "single receive allocation exceeds 4096 rejected")
        try rejectBytes(Data(repeating: 0x20, count: 1_025), label: "unterminated frame exceeding 1024 rejected")
        let base = Data(handshake.dropLast())
        let exactly1024 = Data(repeating: 0x20, count: 1_024 - base.count) + base
        do {
            var d = decoder()
            check(tryResult { try d.receive(exactly1024, lastPing: 0) } == [], "1024-byte partial frame stays bounded without early dispatch")
            check(tryResult { try d.receive(Data([10]), lastPing: 0) } == [.ready], "exact line-size boundary is accepted")
        }
        try rejectBytes(Data([0x20]) + exactly1024 + Data([10]), label: "1025-byte terminated line rejected")
        try rejectBytes(handshake + (try keys(1, [0x28])) + Data("bad\n".utf8), label: "bad coalesced tail fails the receive instead of returning partial keys")

        for values in [[UInt16(0x28), 0x4F, 0x50, 0x51], [0x28, 0x28], [0x04], [UInt16.max]] {
            try rejectBytes(keys(1, values), afterReady: true, label: "key count/uniqueness/whitelist enforced")
        }
        for raw in ["{\"type\":\"keys\",\"sequence\":1,\"usages\":[65536]}\n",
                    "{\"type\":\"keys\",\"sequence\":1,\"usages\":[-1]}\n",
                    "{\"type\":\"keys\",\"sequence\":1,\"usages\":[true]}\n",
                    "{\"type\":\"keys\",\"sequence\":1,\"usages\":[\"40\"]}\n",
                    "{\"type\":\"keys\",\"sequence\":1,\"usages\":null}\n",
                    "{\"type\":\"keys\",\"sequence\":-1,\"usages\":[]}\n",
                    "{\"type\":\"keys\",\"sequence\":18446744073709551616,\"usages\":[]}\n",
                    "{\"type\":\"keys\",\"sequence\":true,\"usages\":[]}\n"] {
            try rejectBytes(Data(raw.utf8), afterReady: true, label: "key element/sequence types and integer bounds enforced")
        }
        for sequence in [UInt64(0), 2, UInt64.max] {
            try rejectBytes(keys(sequence, []), afterReady: true, label: "key sequence begins exactly at one, cannot skip or overflow")
        }
        for sequence in [UInt64(0), 1, 3, UInt64.max] {
            var d = decoder(); _ = try d.receive(handshake + keys(1, [0x28]), lastPing: 0)
            rejects("key sequence cannot replay, regress or jump after accepted first frame") { _ = try d.receive(keys(sequence, []), lastPing: 0) }
        }
        for extra in ["token", "registryID", "unknown"] {
            try rejectBytes(frame(["type": "keys", "sequence": 1, "usages": [0x28], extra: 0]), afterReady: true,
                            label: "keys cannot add identity/unknown fields")
        }
        for sequence in [UInt64(0), 2, UInt64.max] {
            try rejectBytes(pong(sequence), afterReady: true, lastPing: 1, label: "pong cannot be zero or exceed sent ping")
        }
        do {
            var d = decoder(); _ = try d.receive(handshake, lastPing: 0)
            check(tryResult { try d.receive(pong(3), lastPing: 5) } == [.pong(3)], "pong may acknowledge a later actually-sent ping")
            check(tryResult { try d.receive(pong(5), lastPing: 5) } == [.pong(5)], "monotonic acknowledged ping is accepted")
        }
        for sequence in [UInt64(1), 2, 4] {
            var d = decoder(); _ = try d.receive(handshake + pong(2), lastPing: 3)
            rejects("pong replay/regression/future sequence rejected") { _ = try d.receive(pong(sequence), lastPing: 3) }
        }
        try rejectBytes(frame(["type": "pong", "sequence": 1, "extra": true]), afterReady: true, lastPing: 1,
                        label: "pong extra fields rejected")

        // A helper can report failure before acquiring a device. Such control
        // messages carry no input usages and do not establish a ready session.
        do {
            var d = decoder()
            check(tryResult { try d.receive(frame(["type": "error", "code": "hid_input_access", "message": "a\tb\nc\u{1B}"]), lastPing: 0) } == [.failure(code: "hid_input_access", message: "abc")],
                  "error diagnostics are stripped of control characters")
            rejects("early error cannot authenticate later key frames") { _ = try d.receive(keys(1, [0x28]), lastPing: 0) }
        }
        do {
            var d = decoder()
            check(tryResult { try d.receive(frame(["type": "error", "code": "hid_open", "message": "\n\t"]), lastPing: 0) }
                  == [.failure(code: "hid_open", message: "按键辅助进程拒绝了本次会话。")], "empty sanitized error gets safe fallback while code survives")
        }
        do {
            var d = decoder()
            check(tryResult { try d.receive(frame(["type": "error", "code": "x", "message": String(repeating: "a", count: 600)]), lastPing: 0) }
                  == [.failure(code: "x", message: String(repeating: "a", count: 512))], "error UI text bounded independently of protocol frame")
        }
        for code in ["", "UPPER", "hyphen-code", "路径", String(repeating: "a", count: 65)] {
            try rejectBytes(frame(["type": "error", "code": code, "message": "x"]), label: "helper failure code has strict machine-readable syntax")
        }
        try rejectBytes(frame(["type": "error", "code": String(repeating: "a", count: 129), "message": "x"]), label: "error code UTF8 bound enforced")
        try rejectBytes(frame(["type": "error", "code": "x", "message": String(repeating: "字", count: 257)]), label: "error message byte bound is not character count")
        try rejectBytes(frame(["type": "stopped", "reason": String(repeating: "a", count: 257)]), label: "stopped reason bounded")
        try rejectBytes(frame(["type": "stopped", "reason": "done", "usages": [0x28]]), label: "stopped cannot smuggle keys")
        do {
            var d = decoder()
            check(tryResult { try d.receive(frame(["type": "stopped", "reason": "closed"]), lastPing: 0) } == [.stopped("closed")], "bounded pre-ready stopped is a control event only")
        }

        // Duplicate JSON members are ambiguous across Foundation parsers; the
        // authenticated wire protocol should reject them, not select one value.
        let duplicateReady = "{\"type\":\"ready\",\"version\":1,\"token\":\"\(nonce)\",\"token\":\"\(nonce)\",\"registryID\":\(target.registryID),\"locationID\":\(target.locationID)}\n"
        try rejectBytes(Data(duplicateReady.utf8), label: "duplicate ready JSON field rejected")
        try rejectBytes(Data("{\"type\":\"keys\",\"sequence\":1,\"sequence\":1,\"usages\":[40]}\n".utf8), afterReady: true,
                        label: "duplicate key JSON field rejected")
        let escapedDuplicate = "{\"type\":\"ready\",\"version\":1,\"token\":\"\(nonce)\",\"tok\\u0065n\":\"\(nonce)\",\"registryID\":\(target.registryID),\"locationID\":\(target.locationID)}\n"
        try rejectBytes(Data(escapedDuplicate.utf8), label: "escaped spelling of duplicate JSON member rejected")
        do {
            let upper = HIDClientTarget(registryID: UInt64.max, locationID: Int(UInt32.max))
            var d = HIDClientDecoder(token: nonce, target: upper, allowedUsages: allowed)
            let exact = Data("{\"type\":\"ready\",\"version\":1,\"token\":\"\(nonce)\",\"registryID\":18446744073709551615,\"locationID\":4294967295}\n".utf8)
            check(tryResult { try d.receive(exact, lastPing: 0) } == [.ready], "ready preserves full UInt64 registry and UInt32 location identity without floating truncation")
        }

        let digest = String(repeating: "b", count: 64), folder = String(repeating: "c", count: 32)
        let uid: uid_t = 501, pid: pid_t = 4321
        let socket = "/private/var/tmp/OpenRemote-HID-\(uid)-\(folder)/session.sock"
        let permissionSocket = "/private/var/tmp/OpenRemote-HID-Permission-\(uid)-" +
            String(repeating: "d", count: 32) + "/permission.sock"
        let permissionArguments = try HIDPermissionLaunchPlan.arguments(socketPath: permissionSocket,
            clientPID: pid, clientUID: uid)
        check(permissionArguments == ["--permission-ipc", "--socket", permissionSocket,
              "--client-pid", String(pid), "--client-uid", String(uid)],
              "LaunchServices receives only the private socket and fixed main-app peer identity")
        check(HIDPermissionLaunchPlan.helperBundlePath == HIDInstalledHelperContract.helperBundlePath &&
              !permissionArguments.contains("--check-input-access") &&
              !permissionArguments.contains("--request-input-access") &&
              !permissionArguments.contains("--stdout") && !permissionArguments.contains(nonce),
              "argv exposes no prompt operation, result file or authentication nonce")
        do {
            var timeout = HIDPermissionWaiterLifecycle()
            check(timeout.mustHoldGate && !timeout.mayComplete,
                  "a launched permission helper is gated until its exact NSRunningApplication exits")
            check(timeout.markTimedOut() && timeout.mustHoldGate && !timeout.mayComplete,
                  "timeout reports once without releasing arbitration")
            check(!timeout.markTimedOut(), "repeated timeout cannot deliver a second result")
            timeout.recordApplicationTermination()
            check(!timeout.mustHoldGate && timeout.mayComplete,
                  "exact application termination releases the lifecycle gate")
        }
        do {
            var cancelled = HIDPermissionWaiterLifecycle()
            cancelled.markCancelled()
            check(cancelled.cancelled && cancelled.mustHoldGate && !cancelled.claimOutcome(),
                  "cancellation suppresses callbacks and keeps the helper lifecycle gated")
            cancelled.recordApplicationTermination()
            check(!cancelled.mustHoldGate && cancelled.mayComplete,
                  "cancelled probe releases only after exact helper termination")
        }
        for bad in [permissionSocket + "/extra", permissionSocket + "\n",
                    permissionSocket.replacingOccurrences(of: "Permission-501", with: "Permission-502"),
                    permissionSocket.replacingOccurrences(of: String(repeating: "d", count: 32),
                                                           with: String(repeating: "D", count: 32)),
                    "/tmp/OpenRemote-HID-Permission-501-" + String(repeating: "d", count: 32) + "/permission.sock",
                    permissionSocket + "'; id; #"] {
            check(!HIDPermissionLaunchPlan.validSocketPath(bad, uid: uid),
                  "permission socket rejects user mismatch, traversal and command syntax")
            rejects("invalid permission socket never reaches LaunchServices arguments") {
                _ = try HIDPermissionLaunchPlan.arguments(socketPath: bad, clientPID: pid, clientUID: uid)
            }
        }
        rejects("system/root PID cannot enter ordinary permission LaunchServices argv") {
            _ = try HIDPermissionLaunchPlan.arguments(socketPath: permissionSocket, clientPID: 1, clientUID: uid)
        }
        let helperIdentity = HIDHelperPeer(pid: pid, uid: uid, realUID: uid, savedUID: uid,
            seconds: 100, microseconds: 200, path: HIDInstalledHelperContract.helperExecutablePath)
        check(!HIDPermissionProcessObservationPolicy.confirmsExit(.unknown, expected: helperIdentity),
              "transient process identity read failure keeps the permission gate closed")
        check(!HIDPermissionProcessObservationPolicy.confirmsExit(.identity(helperIdentity), expected: helperIdentity),
              "the exact launched helper identity remains in flight")
        let reusedIdentity = HIDHelperPeer(pid: pid, uid: uid, realUID: uid, savedUID: uid,
            seconds: 101, microseconds: 200, path: HIDInstalledHelperContract.helperExecutablePath)
        check(HIDPermissionProcessObservationPolicy.confirmsExit(.absent, expected: helperIdentity) &&
              HIDPermissionProcessObservationPolicy.confirmsExit(.identity(reusedIdentity), expected: helperIdentity),
              "absence or PID reuse with a changed start identity confirms the exact helper exited")
        check(HIDPermissionPeerPolicy.accepts(expectedPID: pid, expectedUID: uid,
            expectedPath: HIDInstalledHelperContract.helperExecutablePath,
            peerPID: pid, peerEUID: uid, peerRUID: uid, identity: helperIdentity),
            "exact NSRunningApplication PID, all user IDs and fixed helper path are required")
        check(!HIDPermissionPeerPolicy.accepts(expectedPID: pid, expectedUID: uid,
            expectedPath: HIDInstalledHelperContract.helperExecutablePath,
            peerPID: pid + 1, peerEUID: uid, peerRUID: uid, identity: helperIdentity),
            "same-UID process with a different PID cannot impersonate the launched helper")
        let wrongPath = HIDHelperPeer(pid: pid, uid: uid, realUID: uid, savedUID: uid,
            seconds: 100, microseconds: 200, path: "/tmp/OpenRemoteHIDCoreService")
        check(!HIDPermissionPeerPolicy.accepts(expectedPID: pid, expectedUID: uid,
            expectedPath: HIDInstalledHelperContract.helperExecutablePath,
            peerPID: pid, peerEUID: uid, peerRUID: uid, identity: wrongPath),
            "same PID metadata with a non-fixed executable path is rejected")
        func script(d: String? = nil, s: String? = nil, t: String? = nil, p: pid_t? = nil,
                    u: uid_t? = nil, target replacement: HIDClientTarget? = nil) throws -> String {
            try HIDSessionScriptBuilder.shellScript(digest: d ?? digest, socket: s ?? socket, token: t ?? nonce,
                pid: p ?? pid, uid: u ?? uid, target: replacement ?? target)
        }
        let shell = try script()
        check(HIDSessionScriptBuilder.validSocketPath(socket, uid: uid), "canonical private socket path accepted")
        check(target.isValid, "normal bound HID target accepted")
        for invalid in [HIDClientTarget(registryID: 0, locationID: 0),
                        HIDClientTarget(registryID: 1, locationID: -1),
                        HIDClientTarget(registryID: 1, locationID: Int(UInt32.max) + 1)] {
            check(!invalid.isValid, "invalid registry/location rejected")
            rejects("invalid target cannot be interpolated") { _ = try script(target: invalid) }
        }
        let maximumTarget = HIDClientTarget(registryID: UInt64.max, locationID: Int(UInt32.max))
        check(maximumTarget.isValid, "numeric target upper boundaries retained without truncation")
        check(tryOptional { try script(p: Int32.max, target: maximumTarget) } != nil, "max valid PID/target represented as decimal only")
        check(tryOptional { try script(target: .init(registryID: 1, locationID: 0)) } != nil, "location zero remains valid")
        for p: pid_t in [Int32.min, -1, 0, 1] { rejects("nonpositive/system PID rejected before interpolation") { _ = try script(p: p) } }
        rejects("root client UID rejected") { _ = try script(u: 0) }
        rejects("socket owner UID mismatch rejected") { _ = try script(u: uid + 1) }
        for bad in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                    String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "ａ", count: 64),
                    nonce + "\n", "'; exit 0; #", "$(id)", "`id`", "${PATH}"] {
            rejects("non-canonical digest cannot enter shell") { _ = try script(d: bad) }
            rejects("non-canonical session token cannot enter shell") { _ = try script(t: bad) }
        }
        let badSockets = [socket + "\n", socket + "\r", socket + "\r\n", socket + "/extra", socket + "\0",
            socket.replacingOccurrences(of: "501", with: "0501"), socket.replacingOccurrences(of: "501", with: "502"),
            socket.replacingOccurrences(of: folder, with: folder.uppercased()),
            socket.replacingOccurrences(of: folder, with: String(repeating: "c", count: 64)),
            socket.replacingOccurrences(of: "session.sock", with: "../session.sock"),
            socket.replacingOccurrences(of: "/private/var/tmp", with: "/tmp"),
            socket + "'; id; #", socket + "$(id)", socket + "`id`", socket + "\nid", " " + socket]
        for bad in badSockets {
            check(!HIDSessionScriptBuilder.validSocketPath(bad, uid: uid), "non-canonical socket path rejected")
            rejects("socket cannot carry shell syntax or trailing separators") { _ = try script(s: bad) }
        }
        let reported = "{\"helperExit\":1,\"cleanupSucceeded\":true,\"result\":{\"success\":false,\"code\":\"hid_input_access\",\"message\":\"denied\\nnow\"}}"
        check(HIDSessionAuthorizationEnvelope.failure(Data(reported.utf8))
              == .init(code: "hid_input_access", message: "deniednow"),
              "authorization envelope preserves a sanitized machine-readable helper failure")
        for bad in [
            reported.replacingOccurrences(of: "\"helperExit\":1", with: "\"helperExit\":0"),
            reported.replacingOccurrences(of: "\"cleanupSucceeded\":true", with: "\"cleanupSucceeded\":false"),
            reported.replacingOccurrences(of: "\"hid_input_access\"", with: "\"UPPER\""),
            reported.dropLast() + ",\"helperExit\":1}",
            "{\"helperExit\":1,\"cleanupSucceeded\":true,\"result\":{\"success\":false,\"code\":\"hid_input_access\",\"code\":\"hid_open\",\"message\":\"x\"}}"
        ] {
            check(HIDSessionAuthorizationEnvelope.failure(Data(bad.utf8)) == nil,
                  "authorization envelope rejects success mismatch, cleanup failure, invalid or duplicate code")
        }
        check(shell.contains("umask 077") && shell.contains("[ ! -L '" + HIDSessionScriptBuilder.helperPath + "' ]"), "fixed installed helper must be a nonlink regular file")
        check(HIDSessionScriptBuilder.helperPath.hasPrefix("/Library/PrivilegedHelperTools/") &&
              !shell.contains(HIDInstalledHelperContract.packagedHelperBundlePath),
              "neither user nor root bootstrap executes the admin-writable Applications payload")
        for protected in ["/Library", "/Library/PrivilegedHelperTools",
                          "/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app",
                          "/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents",
                          "/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents/MacOS"] {
            check(shell.contains("'\(protected)'"), "root bootstrap checks every fixed protected hierarchy component")
        }
        check(shell.contains("protected_metadata=$(/usr/bin/stat -f '%u:%g:%Lp'") &&
              shell.contains("[ \"$protected_metadata\" = '0:0:755' ]"),
              "root bootstrap rejects owner, group or permission drift before hashing")
        check(shell.contains("/usr/bin/stat -f '%u:%g:%Lp:%l'") && shell.contains("[ \"$metadata\" = '0:0:755:1' ]"), "direct helper metadata is root-owned fixed mode and one link")
        check(shell.contains("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum"), "hashing environment excludes injected shell/perl variables")
        check(shell.contains("[ \"${actual%% *}\" = '" + digest + "' ]"), "build-time hash is compared")
        if let hash = shell.range(of: "[ \"${actual%% *}\" = '"), let invocation = shell.range(of: "--session --socket") {
            check(hash.lowerBound < invocation.lowerBound, "no privileged session command before expected digest check")
        } else { check(false, "hash/invocation ordering markers missing") }
        check(shell.contains("--client-pid \(pid) --client-uid \(uid) --token '\(nonce)' --registry-id \(target.registryID) --location-id \(target.locationID)"),
              "only validated numeric identity and exact session token are passed")
        check(shell.contains("'" + HIDSessionScriptBuilder.helperPath + "' --session --socket")
              && shell.contains("helperExit") && shell.contains("cleanupSucceeded\":true"),
              "hash-verified fixed installed helper is invoked directly and result envelope is preserved")
        for forbidden in ["mktemp", "/bin/cp", "chown", "chmod", "/bin/rm", "rmdir", "$stage", "launchctl", "eval "] {
            check(!shell.contains(forbidden), "direct helper bootstrap contains no staging, mutation, daemon or evaluation command")
        }
        let apple = try HIDSessionScriptBuilder.appleScript(digest: digest, socket: socket, token: nonce, pid: pid, uid: uid, target: target)
        let appleText = String(data: apple, encoding: .utf8) ?? ""
        check(appleText.contains("with administrator privileges without altering line endings"), "AppleScript uses system authorization with literal script text")
        check(appleText.contains("linefeed") && !appleText.contains("run script"), "AppleScript transports fixed lines without evaluating caller code")
        for bad in [socket + "\n", socket + "'; id; #"] {
            rejects("AppleScript entry point shares socket validation") {
                _ = try HIDSessionScriptBuilder.appleScript(digest: digest, socket: bad, token: nonce, pid: pid, uid: uid, target: target)
            }
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        print("HIDSessionClientTests: \(checks) checks, \(failures.count) failures; decoder, LaunchServices argv, peer policy and script text only; no process/script/input/audio/authorization.")
        if !failures.isEmpty { exit(1) }
    }

    private static func tryResult(_ operation: () throws -> [HIDClientMessage]) -> [HIDClientMessage]? { try? operation() }
    private static func tryOptional<T>(_ operation: () throws -> T) -> T? { try? operation() }
}
