import Foundation

/// What the virtual cameras serve. A configuration is deliberately tiny for
/// the proof of concept: one source feeds both the front and the back camera.
struct FixtureSource: Codable, Equatable {
    enum Kind: String, Codable {
        case testPattern
        case image
        case movie
    }

    var kind: Kind
    var path: String?

    static let `default` = FixtureSource(kind: .testPattern, path: nil)

    var displayName: String {
        switch kind {
            case .testPattern: "Test Pattern"
            case .image: path.map { ($0 as NSString).lastPathComponent } ?? "Image"
            case .movie: path.map { ($0 as NSString).lastPathComponent } ?? "Movie"
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
