import Foundation

struct ClientMockConfiguration: Codable, Equatable {
    struct Device: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let position: String
        let source: FixtureSource
    }

    let id: String?
    let name: String
    let devices: [Device]

    func validate() throws {
        guard !name.isEmpty else {
            throw ValidationError("configuration name must not be empty")
        }
        guard !devices.isEmpty else {
            throw ValidationError("configuration must contain at least one device")
        }
        var ids = Set<String>()
        for device in devices {
            guard !device.id.isEmpty, !device.name.isEmpty else {
                throw ValidationError("device id and name must not be empty")
            }
            guard ids.insert(device.id).inserted else {
                throw ValidationError("duplicate device id '\(device.id)'")
            }
            guard ["front", "back", "unspecified"].contains(device.position) else {
                throw ValidationError("unsupported position '\(device.position)'")
            }
            switch device.source.kind {
                case .image:
                    guard device.source.dataBase64 != nil || !(device.source.path ?? "").isEmpty else {
                        throw ValidationError("image source for '\(device.id)' needs dataBase64 or path")
                    }
                    if let encoded = device.source.dataBase64,
                       Data(base64Encoded: encoded) == nil {
                        throw ValidationError("image source for '\(device.id)' contains invalid base64")
                    }
                case .movie:
                    guard !(device.source.path ?? "").isEmpty else {
                        throw ValidationError("movie source for '\(device.id)' needs a host path")
                    }
                case .machineCode:
                    guard !(device.source.payload ?? "").isEmpty else {
                        throw ValidationError("machine-code source for '\(device.id)' needs a payload")
                    }
                    let symbology = device.source.symbology?.lowercased() ?? "qr"
                    guard ["qr", "aztec", "pdf417", "code128"].contains(symbology) else {
                        throw ValidationError("unsupported machine-code symbology '\(symbology)'")
                    }
                case .testPattern:
                    break
            }
        }
    }

    var wireDevices: [[String: Any]] {
        devices.map { ["id": $0.id, "name": $0.name, "position": $0.position] }
    }
}

private struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
