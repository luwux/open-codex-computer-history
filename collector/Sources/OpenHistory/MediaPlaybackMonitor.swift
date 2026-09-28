import AppKit
import Darwin
import Foundation
import HistoryCore
import IOKit.pwr_mgt

/// Reports apps that hold display-sleep assertions, which browsers and media
/// players take while video plays. This distinguishes watching from being
/// away when no input events arrive.
enum MediaPlaybackMonitor {
    static func currentOwners() -> [String: MediaPlaybackOwner] {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return [:]
        }
        var owners: [String: MediaPlaybackOwner] = [:]
        for (pid, list) in byProcess {
            guard let assertion = list.first(where: {
                MediaPlayback.displaySleepAssertionTypes.contains(
                    $0[kIOPMAssertionTypeKey as String] as? String ?? ""
                )
            }),
                let owner = owner(
                    processIdentifier: pid.int32Value,
                    assertionName: assertion[kIOPMAssertionNameKey as String] as? String
                )
            else {
                continue
            }
            owners[owner.bundleIdentifier] = owner
        }
        return owners
    }

    private static func owner(
        processIdentifier: pid_t,
        assertionName: String?
    ) -> MediaPlaybackOwner? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count)) > 0,
              let appPath = MediaPlayback.owningApplicationPath(
                  forExecutable: String(cString: buffer)
              ),
              let bundle = Bundle(path: appPath),
              let bundleIdentifier = bundle.bundleIdentifier
        else {
            return nil
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return MediaPlaybackOwner(
            bundleIdentifier: bundleIdentifier,
            name: name,
            assertionName: assertionName
        )
    }
}
