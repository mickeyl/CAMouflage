import Foundation

/// What a virtual camera serves. The menu-bar selection uses one source for
/// both stock cameras; client-supplied configurations may assign one per device.
struct FixtureSource: Codable, Equatable {
    enum Kind: String, Codable {
        case testPattern
        case image
        case movie
        case machineCode
    }

    var kind: Kind
    var path: String?
    var dataBase64: String? = nil
    var symbology: String? = nil
    var payload: String? = nil

    static let `default` = FixtureSource(kind: .testPattern, path: nil)

    var displayName: String {
        switch kind {
            case .testPattern: "Test Pattern"
            case .image: path.map { ($0 as NSString).lastPathComponent } ?? "Image"
            case .movie: path.map { ($0 as NSString).lastPathComponent } ?? "Movie"
            case .machineCode: "\(symbology?.uppercased() ?? "QR") · \(payload ?? "")"
        }
    }

    private static let defaultsKey = "Fixture"

    static func restore() -> FixtureSource {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let fixture = try? JSONDecoder().decode(FixtureSource.self, from: data)
        else {
            return .default
        }
        return fixture
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
