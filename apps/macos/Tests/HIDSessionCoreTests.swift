// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main enum HIDSessionCoreTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); expect(false, message) } catch { expect(true, message) }
        }
        let token = String(repeating: "a", count: 64)
        let socket = "/private/var/tmp/OpenRemote-HID-501-" + String(repeating: "b", count: 32) + "/session.sock"
        let parameters = ["--session", "--socket", socket, "--client-pid", "1234", "--client-uid", "501",
                          "--token", token, "--registry-id", "987654321", "--location-id", "1051036603"]
        let helperHash = String(repeating: "b", count: 64)
        let outerInfo: [String: Any] = ["CFBundleIdentifier": "org.rc001remote.assistant",
            "CFBundleExecutable": "OpenRemoteAssistant", "CFBundleShortVersionString": "0.2.9",
            "CFBundleVersion": "16", "OpenRemoteHIDCoreServiceSHA256": helperHash]
        let serviceInfo: [String: Any] = ["CFBundleIdentifier": "org.rc001remote.assistant.hid-core-service",
            "CFBundleExecutable": "OpenRemoteHIDCoreService", "CFBundleDisplayName": "遥控器按键服务",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2.9", "CFBundleVersion": "16"]
        expect(HIDInstalledHelperContract.packagedHelperBundlePath == "/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteHIDCoreService.app",
               "main app retains an inert signed service payload")
        expect(HIDInstalledHelperContract.helperExecutablePath == "/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents/MacOS/OpenRemoteHIDCoreService",
               "ordinary permission and root session share one protected executable path")
        expect(HIDInstalledHelperContract.helperHash(fromApplicationInfo: outerInfo) == helperHash,
               "outer app pins exact nested helper hash and release identity")
        expect(HIDInstalledHelperContract.validServiceInfo(serviceInfo), "nested app has exact identifier, executable, display name and release identity")
        expect(HIDProtectedPathPolicy.accepts(owner: 0, group: 0, permissions: 0o755,
            typeMatches: true, regular: false, links: 99), "protected directory accepts exact root-wheel 0755 metadata")
        expect(HIDProtectedPathPolicy.accepts(owner: 0, group: 0, permissions: 0o755,
            typeMatches: true, regular: true, links: 1), "protected executable requires one link")
        expect(HIDProtectedPathPolicy.acceptsInfo(owner: 0, group: 0, permissions: 0o644,
            typeMatches: true, links: 1), "protected service Info requires root-wheel 0644 regular file")
        for invalid in [
            HIDProtectedPathPolicy.accepts(owner: 501, group: 0, permissions: 0o755, typeMatches: true, regular: false, links: 1),
            HIDProtectedPathPolicy.accepts(owner: 0, group: 80, permissions: 0o755, typeMatches: true, regular: false, links: 1),
            HIDProtectedPathPolicy.accepts(owner: 0, group: 0, permissions: 0o775, typeMatches: true, regular: false, links: 1),
            HIDProtectedPathPolicy.accepts(owner: 0, group: 0, permissions: 0o755, typeMatches: false, regular: false, links: 1),
            HIDProtectedPathPolicy.accepts(owner: 0, group: 0, permissions: 0o755, typeMatches: true, regular: true, links: 2),
            HIDProtectedPathPolicy.acceptsInfo(owner: 0, group: 0, permissions: 0o600, typeMatches: true, links: 1)
        ] { expect(!invalid, "protected hierarchy rejects owner, group, mode, type or executable link drift") }
        for key in outerInfo.keys {
            var changed = outerInfo; changed[key] = key == "OpenRemoteHIDCoreServiceSHA256" ? String(repeating: "c", count: 63) : "wrong"
            expect(HIDInstalledHelperContract.helperHash(fromApplicationInfo: changed) == nil,
                   "every outer app identity/hash field is mandatory")
        }
        for key in serviceInfo.keys {
            var changed = serviceInfo; changed[key] = "wrong"
            expect(!HIDInstalledHelperContract.validServiceInfo(changed), "every nested service bundle identity field is mandatory")
        }
        let parsed = try HIDSessionArguments.parse(parameters)
        expect(parsed.socketPath == socket && parsed.clientPID == 1234 && parsed.clientUID == 501,
               "only expected private socket and client identity accepted")
        expect(parsed.registryID == 987654321 && parsed.locationID == 1051036603 && parsed.token == token,
               "target locators and nonce preserved without shell parsing")
        let permissionSocket = "/private/var/tmp/OpenRemote-HID-Permission-501-\(String(repeating: "d", count: 32))/permission.sock"
        let permissionValues = ["--permission-ipc", "--socket", permissionSocket,
                                "--client-pid", "1234", "--client-uid", "501"]
        let permission = try HIDPermissionArguments.parse(permissionValues)
        expect(permission.socketPath == permissionSocket && permission.clientPID == 1234 && permission.clientUID == 501,
               "permission argv carries only the private socket and fixed main-app peer identity")
        expect(try HIDSessionInvocation.parse(permissionValues) == .permission(permission),
               "exact authenticated permission IPC mode accepted")
        expect(try HIDSessionInvocation.parse(parameters) == .session(parsed), "session arguments remain one exact mode")
        for values in [["--check-input-access"], ["--request-input-access"],
                       permissionValues + ["--request-input-access"],
                       Array(permissionValues.dropLast()),
                       permissionValues.map { $0 == permissionSocket ? "/tmp/result" : $0 }] {
            rejects("legacy prompt-triggering modes and every altered permission argument are rejected") {
                _ = try HIDSessionInvocation.parse(values)
            }
        }
        try HIDSessionAuthorization.validate(.permission(permission), realUID: 501, effectiveUID: 501)
        try HIDSessionAuthorization.validate(.session(parsed), realUID: 0, effectiveUID: 0)
        expect(true, "permission IPC requires one ordinary identity while session requires full root identity")
        for identity in [(UInt32(0), UInt32(0)), (0, 501), (501, 0), (501, 502)] {
            rejects("permission IPC rejects root and mixed real/effective identities") {
                try HIDSessionAuthorization.validate(.permission(permission), realUID: identity.0, effectiveUID: identity.1)
            }
        }
        for identity in [(UInt32(501), UInt32(501)), (0, 501), (501, 0)] {
            rejects("session mode rejects every identity except real and effective root") {
                try HIDSessionAuthorization.validate(.session(parsed), realUID: identity.0, effectiveUID: identity.1)
            }
        }
        var permissionGate = HIDPermissionCompletionGate()
        let firstPermission = permissionGate.begin()
        permissionGate.cancel(firstPermission)
        expect(!permissionGate.finish(firstPermission), "cancelled permission generation cannot deliver a late completion")
        let secondPermission = permissionGate.begin()
        expect(secondPermission != firstPermission && permissionGate.finish(secondPermission),
               "only the current permission generation may complete once")
        expect(!permissionGate.finish(secondPermission), "permission completion cannot be delivered twice")
        for values in [(true, false, true), (false, false, false), (true, true, false), (false, true, false)] {
            expect(HIDOperationArbitration.canStartSession(hidIdle: values.0, permissionActive: values.1) == values.2,
                   "HID session cannot overlap permission helper operation")
            expect(HIDOperationArbitration.canStartPermission(hidIdle: values.0, permissionActive: values.1) == values.2,
                   "permission helper operation cannot overlap HID session or another probe")
        }
        for values in [Array(parameters.dropLast()), parameters + ["--root", "/tmp"], ["--reload"], []] {
            rejects("missing or extra CLI arguments rejected") { _ = try HIDSessionArguments.parse(values) }
        }

        let granted = HIDInputAccessLogic.reply(rawValue: 0, requested: false)
        let denied = HIDInputAccessLogic.reply(rawValue: 1, requested: true)
        let unknown = HIDInputAccessLogic.reply(rawValue: 999, requested: true)
        expect(granted.status == .granted && !granted.requested && granted.message.contains("管理员接管仍需"),
               "ordinary-user grant never claims a privileged HID session")
        expect(denied.status == .denied && denied.requested,
               "requested means request API was called, independent of grant result")
        expect(unknown.status == .unknown && unknown.requested && unknown.message.contains("未尝试管理员接管"),
               "unknown request remains bounded and does not claim seize")
        for reply in [granted, denied, unknown] {
            expect(try HIDInputAccessReply.decode(reply.encodedLine()) == reply, "permission result has an exact bounded round trip")
        }
        let challenge = String(repeating: "c", count: 64)
        let challengeMessage = HIDPermissionChallenge(challenge: challenge)
        let challengeLine = try challengeMessage.encodedLine()
        expect(try HIDPermissionChallenge.decode(Data(challengeLine.dropLast())) == challengeMessage,
               "helper post-validation challenge has an exact bounded round trip")
        let checkRequest = HIDPermissionRequest(nonce: token, challenge: challenge, operation: .check)
        let requestLine = try checkRequest.encodedLine()
        expect(try HIDPermissionRequest.decode(Data(requestLine.dropLast()), challenge: challenge) == checkRequest,
               "authenticated permission request is bound to the helper's post-validation challenge")
        var fragmentedGate = try HIDPermissionRequestGate(challenge: challenge)
        for byte in requestLine { try fragmentedGate.receive(Data([byte])) }
        expect(try fragmentedGate.finish() == checkRequest,
               "permission gate releases one arbitrarily fragmented request only after EOF")
        rejects("permission gate rejects two coalesced requests before releasing either") {
            var gate = try HIDPermissionRequestGate(challenge: challenge)
            try gate.receive(requestLine + requestLine)
        }
        rejects("permission gate rejects a half-frame EOF before any side effect") {
            var gate = try HIDPermissionRequestGate(challenge: challenge)
            try gate.receive(Data(requestLine.dropLast()))
            _ = try gate.finish()
        }
        rejects("permission gate rejects trailing partial data before any side effect") {
            var gate = try HIDPermissionRequestGate(challenge: challenge)
            try gate.receive(requestLine + Data("partial".utf8))
            _ = try gate.finish()
        }
        rejects("permission gate is one-shot after releasing its request") {
            var gate = try HIDPermissionRequestGate(challenge: challenge)
            try gate.receive(requestLine)
            _ = try gate.finish()
            _ = try gate.finish()
        }
        let permissionResponse = HIDPermissionResponse(nonce: token, challenge: challenge, reply: granted)
        let responseLine = try permissionResponse.encodedLine()
        expect(try HIDPermissionResponse.decode(Data(responseLine.dropLast()), nonce: token,
            challenge: challenge, operation: .check)
               == permissionResponse, "authenticated permission result is correlated to nonce and operation")
        for bad in [
            "{\"type\":\"permission\",\"version\":2,\"nonce\":\"\(token)\",\"challenge\":\"\(challenge)\",\"operation\":\"request\",\"operation\":\"check\"}",
            "{\"type\":\"permission\",\"version\":2,\"nonce\":\"\(token)\",\"challenge\":\"\(challenge)\",\"operation\":\"invalid\"}",
            "{\"type\":\"permission\",\"version\":2,\"nonce\":\"\(token)\",\"challenge\":\"\(challenge)\",\"operation\":\"request\",\"extra\":true}",
            "{\"type\":\"permission\",\"version\":1,\"nonce\":\"\(token)\",\"operation\":\"request\"}"
        ] {
            rejects("permission request rejects duplicate, invalid and extra operation data") {
                _ = try HIDPermissionRequest.decode(Data(bad.utf8), challenge: challenge)
            }
        }
        rejects("permission request queued before helper validation cannot guess the later challenge") {
            _ = try HIDPermissionRequest.decode(Data(requestLine.dropLast()),
                challenge: String(repeating: "d", count: 64))
        }
        for bad in [
            "{\"type\":\"permission-challenge\",\"version\":2,\"challenge\":\"short\"}",
            "{\"type\":\"permission-challenge\",\"version\":1,\"challenge\":\"\(challenge)\"}",
            "{\"type\":\"permission-challenge\",\"version\":2,\"challenge\":\"\(challenge)\",\"extra\":true}",
            "{\"type\":\"permission-challenge\",\"version\":2,\"challenge\":\"\(challenge)\",\"challenge\":\"\(challenge)\"}"
        ] {
            rejects("permission challenge rejects truncation, old versions, extra and duplicate fields") {
                _ = try HIDPermissionChallenge.decode(Data(bad.utf8))
            }
        }
        rejects("permission result rejects a different session nonce") {
            _ = try HIDPermissionResponse.decode(Data(responseLine.dropLast()),
                nonce: String(repeating: "e", count: 64), challenge: challenge, operation: .check)
        }
        rejects("permission result rejects requested flag inconsistent with authenticated operation") {
            _ = try HIDPermissionResponse.decode(Data(responseLine.dropLast()), nonce: token,
                challenge: challenge, operation: .request)
        }
        rejects("permission result rejects a different helper challenge") {
            _ = try HIDPermissionResponse.decode(Data(responseLine.dropLast()), nonce: token,
                challenge: String(repeating: "d", count: 64), operation: .check)
        }
        for text in [
            "{\"success\":true,\"status\":\"granted\",\"requested\":false,\"message\":\"ok\",\"status\":\"denied\"}",
            "{\"success\":true,\"status\":\"granted\",\"requested\":false,\"message\":\"ok\",\"extra\":1}",
            "{\"success\":true,\"status\":\"invalid\",\"requested\":false,\"message\":\"ok\"}",
            "{\"success\":true,\"status\":\"granted\",\"requested\":\"false\",\"message\":\"ok\"}",
            "{\"success\":true,\"status\":\"granted\",\"requested\":false,\"message\":\"\(String(repeating: "a", count: 513))\"}"
        ] {
            rejects("malformed, duplicate or expanded permission output rejected") {
                _ = try HIDInputAccessReply.decode(Data(text.utf8))
            }
        }
        for change in [(1, "--unknown"), (3, "--socket"), (4, "0"), (4, "1"), (4, "-1"),
                       (6, "0"), (6, "-1"), (6, "502"), (8, String(repeating: "A", count: 64)),
                       (8, "token;command"), (10, "0"), (10, "-1"), (12, "4294967296"),
                       (2, "/tmp/session.sock"), (2, socket + "/../other"), (2, socket.replacingOccurrences(of: "session.sock", with: "other.sock"))] {
            var values = parameters; values[change.0] = change.1
            rejects("unsafe argument \(change.0) rejected") { _ = try HIDSessionArguments.parse(values) }
        }

        for usage in HIDSessionRules.verifiedUsages {
            expect(try HIDSessionRules.report(id: 1, bytes: [1, UInt8(usage), 0, 0, 0, 0, 0]) == [usage],
                   "verified keyboard usage is delivered")
        }
        expect(try HIDSessionRules.report(id: 1, bytes: [1, 0x52, 0, 0x51, 0, 0x4F, 0]) == [0x52, 0x51, 0x4F], "three slots delivered as full state")
        expect(try HIDSessionRules.report(id: 1, bytes: [0x35, 0, 0x66, 0, 0, 0]) == [0x35, 0x66],
               "six-byte RC003 payload without embedded report ID is accepted")
        expect(try HIDSessionRules.report(id: 1, bytes: [1, 0x52, 0, 0x52, 0, 0x3E, 0]) == [0x52], "duplicates coalesce; unverified HID microphone never forwarded")
        expect(try HIDSessionRules.report(id: 1, bytes: [1, 0x66, 0, 0, 0, 0xFF, 0xFF]) == [0x66], "RC003 power is delivered while unknown codes are ignored")
        expect(try HIDSessionRules.report(id: 1, bytes: [1, 0, 0, 0, 0, 0, 0]) == [], "all-up frame survives")
        expect(try HIDSessionRules.report(id: 5, bytes: [0xAA, 0xBB]) == nil, "vendor/audio reports ignored")
        for bytes: [UInt8] in [[1], [1, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0],
                              [1, 1, 0, 0, 0, 0, 0], [1, 0, 0, 2, 0, 0, 0], [1, 0, 0, 0, 0, 3, 0]] {
            rejects("bad report cannot strand a held key") { _ = try HIDSessionRules.report(id: 1, bytes: bytes) }
        }
        let hello = HIDSessionMessage(type: "hello", version: 1, token: token)
        let ping = HIDSessionMessage(type: "ping", sequence: 1)
        let stop = HIDSessionMessage(type: "stop")
        let stream = try hello.encodedLine() + ping.encodedLine() + stop.encodedLine()
        for chunk in 1...17 {
            var buffer = HIDSessionLineBuffer(), messages: [HIDSessionMessage] = []
            for offset in stride(from: 0, to: stream.count, by: chunk) {
                for line in try buffer.append(stream.subdata(in: offset..<min(offset + chunk, stream.count))) {
                    messages.append(try HIDSessionMessage.decodeClient(line))
                }
            }
            expect(messages == [hello, ping, stop], "fragmented/coalesced Unix stream retains frame boundaries")
        }
        for text in ["", "{}", "[]", "{\"type\":\"ready\"}", "{\"type\":\"stop\",\"target\":2}",
                     "{\"type\":\"ping\"}", "{\"type\":\"ping\",\"sequence\":true}",
                     "{\"type\":\"ping\",\"sequence\":-1}", "{\"type\":\"ping\",\"sequence\":1.5}",
                     "{\"type\":\"hello\",\"version\":true,\"token\":\"\(token)\"}"] {
            rejects("invalid or wrong-direction message cannot reach device") { _ = try HIDSessionMessage.decodeClient(Data(text.utf8)) }
        }
        for text in [
            "{\"type\":\"hello\",\"version\":1,\"token\":\"\(token)\",\"token\":\"\(token)\"}",
            "{\"type\":\"hello\",\"version\":2,\"version\":1,\"token\":\"\(token)\"}",
            "{\"type\":\"ping\",\"sequence\":999,\"sequence\":1}",
            "{\"type\":\"ping\",\"sequence\":999,\"\\u0073equence\":1}",
            "{\"type\":\"stop\",\"\\u0074ype\":\"stop\"}",
            "{\"one\":{\"x\":1,\"x\":2}}"
        ] {
            rejects("duplicate JSON fields including escaped keys are rejected before interpretation") {
                try HIDSessionJSON.validateUniqueMembers(Data(text.utf8))
            }
        }
        for text in ["{\"one\":{\"x\":1},\"two\":{\"x\":2}}", "{\"text\":\"a \\\"key\\\": [ brace {\"}",
                     "{\"array\":[{\"x\":1},{\"x\":2}]}"] {
            try HIDSessionJSON.validateUniqueMembers(Data(text.utf8))
            expect(true, "independent nested objects and escaped string content do not create false duplicate keys")
        }
        do {
            var buffer = HIDSessionLineBuffer()
            expect(try buffer.append(Data(repeating: 65, count: 1024)).isEmpty, "exact bounded fragment may await newline")
            rejects("unterminated frame cannot grow without bound") { _ = try buffer.append(Data([65])) }
        }
        do {
            var buffer = HIDSessionLineBuffer()
            rejects("empty frame rejected") { _ = try buffer.append(Data([10])) }
        }
        var lease = HIDSessionLease(token: token, now: 100)
        rejects("no commands before nonce authentication") { _ = try lease.accept(ping, now: 100.1) }
        rejects("wrong nonce rejected") { _ = try lease.accept(.init(type: "hello", version: 1, token: String(repeating: "c", count: 64)), now: 100.1) }
        rejects("wrong protocol version rejected") { _ = try lease.accept(.init(type: "hello", version: 2, token: token), now: 100.1) }
        expect(try lease.accept(hello, now: 100.1) == nil && lease.authenticated, "one authenticated hello permits opening")
        rejects("second hello cannot change target or reset lifetime") { _ = try lease.accept(hello, now: 100.2) }
        expect(try lease.accept(ping, now: 101) == .init(type: "pong", sequence: 1), "heartbeat acknowledged exactly")
        rejects("replayed ping cannot renew lease") { _ = try lease.accept(ping, now: 101.5) }
        rejects("skipped sequence rejected") { _ = try lease.accept(.init(type: "ping", sequence: 3), now: 101.5) }
        expect(lease.lastHeartbeat == 101, "invalid traffic does not update lease")
        expect(lease.expired(at: 103.9) == nil && lease.expired(at: 104) == "heartbeat_timeout", "idle clock expires with no dependence on HID events")
        rejects("late heartbeat cannot revive expired session") { _ = try lease.accept(.init(type: "ping", sequence: 2), now: 104) }
        var stopping = HIDSessionLease(token: token, now: 0)
        _ = try stopping.accept(hello, now: 0)
        expect(try stopping.accept(stop, now: 1)?.reason == "requested" && stopping.stopped, "explicit stop is terminal")
        rejects("closed lease cannot resume") { _ = try stopping.accept(ping, now: 1.1) }

        let watchdog = HIDSessionWatchdog(now: 0)
        expect(watchdog.expiry(at: 2.49) == nil && watchdog.expiry(at: 2.5) == "heartbeat_timeout", "independent deadline has margin before three seconds")
        watchdog.heartbeat(at: 2)
        expect(watchdog.expiry(at: 4.49) == nil && watchdog.expiry(at: 4.5) == "heartbeat_timeout", "only explicit heartbeat extends independent deadline")
        watchdog.heartbeat(at: 1)
        expect(watchdog.expiry(at: 4.5) == "heartbeat_timeout", "backward timestamp cannot extend watchdog")
        watchdog.heartbeat(at: HIDSessionRules.maximumDuration - 1)
        expect(watchdog.expiry(at: HIDSessionRules.maximumDuration) == "maximum_duration", "heartbeats cannot bypass eight-hour maximum")
        watchdog.disarm()
        expect(watchdog.expiry(at: HIDSessionRules.maximumDuration + 100) == nil, "after close acknowledgement watchdog disarms")
        let invalidClock = HIDSessionWatchdog(now: 10)
        expect(invalidClock.expiry(at: 9) == "clock_invalid" && invalidClock.expiry(at: .nan) == "clock_invalid", "invalid monotonic time fails closed")
        let blockedWorker = DispatchQueue(label: "fake.blocked.hid.worker")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), inspected = DispatchSemaphore(value: 0)
        blockedWorker.async { entered.signal(); release.wait() }
        entered.wait()
        let independent = HIDSessionWatchdog(now: 0)
        DispatchQueue(label: "fake.independent.watchdog").async {
            if independent.expiry(at: 3) == "heartbeat_timeout" { inspected.signal() }
        }
        expect(inspected.wait(timeout: .now() + 1) == .success, "watchdog state remains queryable while HID worker is blocked")
        release.signal()

        expect(HIDSessionRules.openFailure(-536870207).code == "hid_privilege", "reported 0xe00002c1 is privilege failure")
        expect(HIDSessionRules.openFailure(Int32(bitPattern: 0xe00002e2)).code == "hid_input_access", "separate helper TCC refusal preserved")
        expect(HIDSessionRules.openFailure(Int32(bitPattern: 0xe00002c5)).code == "hid_busy", "actual exclusive access classified separately")
        expect(HIDSessionRules.openFailure(-1).code == "hid_open", "unknown error does not invent permission or occupancy cause")
        print("HIDSessionCoreTests: \(checks) checks passed; pure wire/report/lease fixtures and inert queues only; no helper, permissions or HID device opened.")
    }
}
