import AVFoundation
import CAMouflage
import XCTest

final class ClientFixtureTests: XCTestCase {
    private let deviceID = "cmf-test-qr"
    private let payload = "camouflage://client-fixture/qr"

    override func tearDown() {
        CAMouflageClearMockConfiguration()
        super.tearDown()
    }

    func testClientSuppliedQRCodeReachesMetadataDelegate() throws {
        guard CAMouflageIsProviderConnected() else {
            XCTFail("Start CAMouflage-Mac in Mock mode before running this test.")
            return
        }

        let configuration: [String: Any] = [
            "name": "Headless QR fixture",
            "devices": [[
                "id": deviceID,
                "name": "Headless QR Camera",
                "position": "back",
                "source": [
                    "kind": "machineCode",
                    "symbology": "qr",
                    "payload": payload,
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration)
        guard CAMouflageSetMockConfiguration(data) else {
            XCTFail("Provider disconnected before the client fixture could be sent.")
            return
        }

        let device = try XCTUnwrap(waitForDevice(id: deviceID, timeout: 5),
                                   "Provider did not publish client device '\(deviceID)'.")
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let metadataOutput = AVCaptureMetadataOutput()
        let detected = expectation(description: "QR metadata delivered")
        let delegate = MetadataDelegate(payload: payload, expectation: detected)

        session.beginConfiguration()
        XCTAssertTrue(session.canAddInput(input))
        session.addInput(input)
        XCTAssertTrue(session.canAddOutput(metadataOutput))
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(delegate, queue: DispatchQueue(label: "camouflage.test.metadata"))
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }

        wait(for: [detected], timeout: 10)
    }

    private func waitForDevice(id: String, timeout: TimeInterval) -> AVCaptureDevice? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            if let device = discovery.devices.first(where: { $0.uniqueID == id }) {
                return device
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }
}

private final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let payload: String
    private let expectation: XCTestExpectation
    private var didFulfill = false

    init(payload: String, expectation: XCTestExpectation) {
        self.payload = payload
        self.expectation = expectation
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFulfill,
              metadataObjects
            .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
            .contains(payload)
        else {
            return
        }
        didFulfill = true
        expectation.fulfill()
    }
}
