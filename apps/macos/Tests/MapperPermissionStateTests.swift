import Foundation

private enum Failure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.assertion(message) }
}

@main
private struct MapperPermissionStateTests {
    static func main() throws {
        var count = 0
        func check(_ label: String, _ body: () throws -> Void) throws {
            try body()
            count += 1
            print("ok \(count) - \(label)")
        }

        try check("helper protocol granted maps to granted") {
            try expect(HIDServiceInputPermissionState.from(.granted) == .granted, "granted mapping")
        }
        try check("helper protocol denied maps to denied") {
            try expect(HIDServiceInputPermissionState.from(.denied) == .denied, "denied mapping")
        }
        try check("helper protocol unknown remains unknown") {
            try expect(HIDServiceInputPermissionState.from(.unknown) == .unknown, "unknown mapping")
        }
        try check("only typed hid input access failure changes permission") {
            try expect(HIDServiceInputPermissionState.fromSessionFailure(code: "hid_input_access") == .denied,
                       "typed permission failure")
            try expect(HIDServiceInputPermissionState.fromSessionFailure(code: "hid_busy") == nil,
                       "busy must not be permission denial")
            try expect(HIDServiceInputPermissionState.fromSessionFailure(code: "hid_disconnected") == nil,
                       "disconnect must not be permission denial")
        }
        try check("main input permission blocks first") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: false, accessibility: false,
                                                       hidService: .unknown)
            try expect(result == .mainInputMonitoring, "main input blocker")
        }
        try check("accessibility blocks before helper") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: false,
                                                       hidService: .granted)
            try expect(result == .accessibility, "accessibility blocker")
        }
        try check("checking helper never passes admin gate") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: true,
                                                       hidService: .checking)
            try expect(result == .hidService(.checking), "checking helper blocker")
        }
        try check("denied helper never passes admin gate") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: true,
                                                       hidService: .denied)
            try expect(result == .hidService(.denied), "denied helper blocker")
        }
        try check("unknown helper never passes admin gate") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: true,
                                                       hidService: .unknown)
            try expect(result == .hidService(.unknown), "unknown helper blocker")
        }
        try check("all three proven permissions pass admin gate") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: true,
                                                       hidService: .granted)
            try expect(result == nil, "granted gate")
        }
        try check("actual root denial blocks a later user-granted snapshot") {
            let result = MappingPermissionGate.blocker(mainInputMonitoring: true, accessibility: true,
                                                       hidService: .granted, rootSessionDenied: true)
            try expect(result == .hidServiceRootDenied, "root denial latch")
        }
        try check("automatic refresh cannot clear actual root denial") {
            try expect(!HIDServicePermissionRefreshPolicy.permitsCheck(rootSessionDenied: true,
                                                                       userInitiated: false),
                       "automatic denial latch")
        }
        try check("explicit user refresh may recheck after root denial") {
            try expect(HIDServicePermissionRefreshPolicy.permitsCheck(rootSessionDenied: true,
                                                                      userInitiated: true),
                       "explicit retry policy")
        }
        try check("normal automatic refresh remains available before root denial") {
            try expect(HIDServicePermissionRefreshPolicy.permitsCheck(rootSessionDenied: false,
                                                                      userInitiated: false),
                       "normal automatic refresh")
        }
        try check("quit waits for Typeless physical-key restoration") {
            try expect(!TypelessQuitGate.canFinish(
                voiceStopped: true,
                hidStopped: true,
                defaultInputSettled: true,
                physicalKeyRestored: false
            ), "failed HID restore must not be reported as a clean quit")
        }
        try check("quit may finish after every independent cleanup settles") {
            try expect(TypelessQuitGate.canFinish(
                voiceStopped: true,
                hidStopped: true,
                defaultInputSettled: true,
                physicalKeyRestored: true
            ), "complete cleanup gate")
        }
        try check("preview flag selects denied without a live helper") {
            let state = HIDServiceInputPermissionState.preview(
                arguments: ["preview", "--hid-input-preview-state", "denied"], plistValue: nil)
            try expect(state == .denied, "preview denied")
        }
        try check("preview alias selects checking") {
            let state = HIDServiceInputPermissionState.preview(
                arguments: ["preview", "--hid-input-access-preview", "checking"], plistValue: nil)
            try expect(state == .checking, "preview checking")
        }
        try check("preview command line overrides plist") {
            let state = HIDServiceInputPermissionState.preview(
                arguments: ["preview", "--hid-input-preview-state", "granted"], plistValue: "denied")
            try expect(state == .granted, "preview precedence")
        }
        try check("preview plist supplies UI-only state") {
            let state = HIDServiceInputPermissionState.preview(arguments: ["preview"], plistValue: "granted")
            try expect(state == .granted, "preview plist")
        }
        try check("invalid preview state fails closed") {
            let state = HIDServiceInputPermissionState.preview(
                arguments: ["preview", "--hid-input-preview-state", "ready"], plistValue: nil)
            try expect(state == .unknown, "invalid preview state")
        }
        try check("first audio inspection launches one underlying read") {
            var state = AudioInspectionFlightState()
            try expect(state.request() == .launch(1), "first request must launch generation one")
            try expect(state.inFlightGeneration == 1 && !state.timedOut, "first read is tracked in flight")
        }
        try check("overlapping audio inspection joins the one in-flight read") {
            var state = AudioInspectionFlightState()
            _ = state.request()
            try expect(state.request() == .join(1), "overlap must not enqueue a second read")
            try expect(state.inFlightGeneration == 1, "joined read keeps the original generation")
        }
        try check("audio inspection timeout keeps the underlying read in flight") {
            var state = AudioInspectionFlightState()
            _ = state.request()
            try expect(state.markTimedOut(generation: 1), "current read may time out once")
            try expect(state.inFlightGeneration == 1 && state.timedOut,
                       "UI timeout must not clear the underlying in-flight marker")
            try expect(!state.markTimedOut(generation: 1), "same timeout cannot complete waiters twice")
        }
        try check("periodic refresh is bounded while timed-out read is still executing") {
            var state = AudioInspectionFlightState()
            _ = state.request()
            _ = state.markTimedOut(generation: 1)
            for _ in 0..<100 {
                try expect(state.request() == .completeFromTimedOutReading(1),
                           "timed-out in-flight read must reject further queue work")
            }
            try expect(state.generation == 1, "blocked refreshes must not allocate new generations")
        }
        try check("late audio result clears flight without reviving timed-out waiters") {
            var state = AudioInspectionFlightState()
            _ = state.request()
            _ = state.markTimedOut(generation: 1)
            try expect(state.finish(generation: 1) == .afterTimeout, "late completion is distinguished")
            try expect(state.inFlightGeneration == nil && !state.timedOut, "late return releases the flight")
            try expect(state.request() == .launch(2), "only a real return permits the next read")
        }
        try check("stale audio timeout and completion cannot alter a newer generation") {
            var state = AudioInspectionFlightState()
            _ = state.request()
            try expect(state.finish(generation: 1) == .onTime, "first read completes normally")
            try expect(state.request() == .launch(2), "second read starts")
            try expect(!state.markTimedOut(generation: 1), "stale timeout ignored")
            try expect(state.finish(generation: 1) == nil, "stale completion ignored")
            try expect(state.inFlightGeneration == 2 && !state.timedOut, "new generation remains intact")
        }

        print("PASS \(count) mapper permission state tests")
    }
}
