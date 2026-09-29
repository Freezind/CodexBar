import Foundation

extension ProviderConfig {
    /// Opt-in: start an idle 5-hour session window by sending one minimal CLI prompt.
    public var sessionAutoStartEnabled: Bool? {
        get { self.extensionValue(forKey: "sessionAutoStartEnabled") }
        set { self.setExtensionValue(newValue, forKey: "sessionAutoStartEnabled") }
    }
}
