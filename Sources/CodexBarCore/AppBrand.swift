import Foundation

/// Identity of this fork's app bundle. Keep in sync with `fork.env`, which the packaging scripts read.
///
/// Only identifiers that locate the app's own settings and shared container live here. Internal labels (log
/// subsystems, window identifiers, cache directories, hash salts) intentionally keep upstream's names so upstream
/// merges stay small.
public enum AppBrand {
    public static let displayName = "AIUsageBar"
    public static let releaseBundleID = "com.bonsai.aiusagebar"
    public static let debugBundleID = "\(releaseBundleID).debug"
}
