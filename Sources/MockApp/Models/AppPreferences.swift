import Foundation

enum AppPreferences {
    static let controlWindowBehaviorDidChange = Notification.Name("AppPreferences.controlWindowBehaviorDidChange")

    private static let dismissKey = "DismissControlWindowOnDeactivate"

    static var dismissControlWindowOnDeactivate: Bool {
        get { UserDefaults.standard.bool(forKey: dismissKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dismissKey)
            NotificationCenter.default.post(name: controlWindowBehaviorDidChange, object: nil)
        }
    }
}
