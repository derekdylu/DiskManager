import AppKit
import Foundation

/// Full Disk Access cannot be requested with an API — the user has to toggle it in System Settings.
/// Without it, macOS pops a separate permission dialog for Desktop, Documents, Downloads, removable
/// volumes, network volumes… every time a scan first touches them, and refuses TCC-protected folders outright.
enum FullDiskAccess {
    /// Paths that TCC protects; without FDA `open(2)` fails with EPERM, with FDA it succeeds
    private static let probes = [
        "Library/Safari", "Library/Mail", "Library/Messages", "Library/Cookies",
        "Library/HomeKit", "Library/Suggestions", "Library/Metadata/CoreSpotlight",
    ]

    static var isGranted: Bool {
        let home = NSHomeDirectory()
        var sawDenial = false
        for probe in probes {
            let fd = open(home + "/" + probe, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { sawDenial = true }
        }
        // Nothing protected exists to test against (fresh account): nothing to be denied either
        return !sawDenial
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
