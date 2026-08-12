import Foundation

enum ProviderMode: String, CaseIterable, Identifiable {
    case off
    case mock
    case passthrough

    var id: String { rawValue }

    var title: String {
        switch self {
            case .off: "Off"
            case .mock: "Mock"
            case .passthrough: "Passthrough"
        }
    }
}
