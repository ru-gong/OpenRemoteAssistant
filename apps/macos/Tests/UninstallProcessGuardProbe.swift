// Read-only probe for the native uninstall process guard. Never instantiate
// the uninstall coordinator or a filesystem/receipt mutation adapter.
import Foundation
import Darwin

@main
struct UninstallProcessGuardProbe {
    static func main() {
        do {
            try NativeUninstallProcessChecks().checkStopped()
            print("process guard permits proceeding; no uninstall executed")
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(5)
        }
    }
}
