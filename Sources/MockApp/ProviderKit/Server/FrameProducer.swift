import AVFoundation
import AppKit
import CoreImage
import CoreText
import UniformTypeIdentifiers

struct ProducedFrame {
    let jpeg: Data
    let width: UInt16
    let height: UInt16
}

protocol FrameProducer: AnyObject {
    var fps: Int { get }
    func nextFrame() -> ProducedFrame?
}

func makeFrameProducer(for fixture: FixtureSource) -> FrameProducer {
    switch fixture.kind {
        case .testPattern:
            return TestPatternProducer()
        case .image:
            if let encoded = fixture.dataBase64,
               let data = Data(base64Encoded: encoded),
               let producer = ImageProducer(data: data) {
                return producer
            }
            if let path = fixture.path, let producer = ImageProducer(path: path) {
                return producer
            }
            return TestPatternProducer()
        case .movie:
            if let path = fixture.path, let producer = MovieProducer(path: path) {
                return producer
            }
            return TestPatternProducer()
        case .machineCode:
            if let producer = MachineCodeProducer(
                symbology: fixture.symbology ?? "qr",
                payload: fixture.payload ?? ""
            ) {
                return producer
            }
            return TestPatternProducer()
    }
}

private func jpegData(from image: CGImage, quality: Double = 0.7) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

// MARK: - Test Pattern

/// SMPTE-style color bars with a sweeping line and a timestamp burn-in, so
/// liveness is obvious at a glance.
final class TestPatternProducer: FrameProducer {
    let fps = 15
    private let width = 1280
    private let height = 720
    private var frameCounter: UInt64 = 0

    private static let barColors: [CGColor] = [
        CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
        CGColor(red: 0.75, green: 0.75, blue: 0.00, alpha: 1),
        CGColor(red: 0.00, green: 0.75, blue: 0.75, alpha: 1),
        CGColor(red: 0.00, green: 0.75, blue: 0.00, alpha: 1),
        CGColor(red: 0.75, green: 0.00, blue: 0.75, alpha: 1),
        CGColor(red: 0.75, green: 0.00, blue: 0.00, alpha: 1),
        CGColor(red: 0.00, green: 0.00, blue: 0.75, alpha: 1),
    ]

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter
    }()

    func nextFrame() -> ProducedFrame? {
        frameCounter += 1
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            return nil
        }

        let barWidth = CGFloat(width) / CGFloat(Self.barColors.count)
        for (index, color) in Self.barColors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: CGFloat(height) / 4,
                                width: barWidth, height: CGFloat(height) * 3 / 4))
        }

        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 4))

        let sweepPeriod = fps * 4
        let sweepX = CGFloat(Int(frameCounter) % sweepPeriod) / CGFloat(sweepPeriod) * CGFloat(width)
        context.setFillColor(CGColor(gray: 1.0, alpha: 0.9))
        context.fill(CGRect(x: sweepX, y: 0, width: 4, height: CGFloat(height)))

        let timestamp = Self.timestampFormatter.string(from: Date())
        drawText("CAMouflage  \(timestamp)  #\(frameCounter)", in: context, at: CGPoint(x: 24, y: 60))

        guard let image = context.makeImage(), let jpeg = jpegData(from: image) else {
            return nil
        }
        return ProducedFrame(jpeg: jpeg, width: UInt16(width), height: UInt16(height))
    }

    private func drawText(_ string: String, in context: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 42, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1.0, alpha: 1.0),
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }
}

// MARK: - Static Image

final class ImageProducer: FrameProducer {
    let fps = 5
    private let frame: ProducedFrame

    init?(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        guard let frame = Self.makeFrame(from: image) else { return nil }
        self.frame = frame
    }

    init?(data: Data) {
        guard let image = NSImage(data: data), let frame = Self.makeFrame(from: image) else { return nil }
        self.frame = frame
    }

    private static func makeFrame(from image: NSImage) -> ProducedFrame? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let scaled = scaledDown(cgImage, maxDimension: 1920)
        guard let jpeg = jpegData(from: scaled) else { return nil }
        return ProducedFrame(jpeg: jpeg, width: UInt16(scaled.width), height: UInt16(scaled.height))
    }

    func nextFrame() -> ProducedFrame? {
        frame
    }

    private static func scaledDown(_ image: CGImage, maxDimension: Int) -> CGImage {
        let width = image.width
        let height = image.height
        guard max(width, height) > maxDimension else { return image }
        let scale = CGFloat(maxDimension) / CGFloat(max(width, height))
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)
        guard let context = CGContext(data: nil, width: newWidth, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
}

// MARK: - Machine Code

final class MachineCodeProducer: FrameProducer {
    let fps = 5
    private let frame: ProducedFrame

    init?(symbology: String, payload: String) {
        guard !payload.isEmpty else { return nil }
        let filterName: String
        switch symbology.lowercased() {
            case "qr": filterName = "CIQRCodeGenerator"
            case "aztec": filterName = "CIAztecCodeGenerator"
            case "pdf417": filterName = "CIPDF417BarcodeGenerator"
            case "code128": filterName = "CICode128BarcodeGenerator"
            default: return nil
        }
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        if filterName == "CIQRCodeGenerator" {
            filter.setValue("M", forKey: "inputCorrectionLevel")
        }
        guard let code = filter.outputImage else { return nil }

        let canvasWidth = 1280
        let canvasHeight = 720
        let availableWidth = CGFloat(canvasWidth - 160)
        let availableHeight = CGFloat(canvasHeight - 120)
        let scale = max(1, floor(min(availableWidth / code.extent.width,
                                     availableHeight / code.extent.height)))
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let codeImage = ciContext.createCGImage(scaled, from: scaled.extent.integral),
              let canvas = CGContext(data: nil, width: canvasWidth, height: canvasHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                         CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            return nil
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        canvas.interpolationQuality = .none
        let origin = CGPoint(x: (CGFloat(canvasWidth) - CGFloat(codeImage.width)) / 2,
                             y: (CGFloat(canvasHeight) - CGFloat(codeImage.height)) / 2)
        canvas.draw(codeImage, in: CGRect(origin: origin,
                                         size: CGSize(width: codeImage.width, height: codeImage.height)))
        guard let image = canvas.makeImage(), let jpeg = jpegData(from: image, quality: 0.95) else { return nil }
        frame = ProducedFrame(jpeg: jpeg, width: UInt16(canvasWidth), height: UInt16(canvasHeight))
    }

    func nextFrame() -> ProducedFrame? { frame }
}

// MARK: - Looping Movie

final class MovieProducer: FrameProducer {
    private(set) var fps = 15
    private let asset: AVURLAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init?(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        asset = AVURLAsset(url: url)

        // Synchronous track loading is acceptable here: producers are created
        // on the frame server's I/O queue, never on the main thread.
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let nominal = Int(track.nominalFrameRate.rounded())
        fps = min(max(nominal, 1), 15)
        guard startReader() else { return nil }
    }

    private func startReader() -> Bool {
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset)
        else {
            return false
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        self.reader = reader
        self.output = output
        return true
    }

    func nextFrame() -> ProducedFrame? {
        guard let output else { return nil }
        var sampleBuffer = output.copyNextSampleBuffer()
        if sampleBuffer == nil {
            guard startReader() else { return nil }
            sampleBuffer = self.output?.copyNextSampleBuffer()
        }
        guard let sampleBuffer, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else {
            return nil
        }
        return ProducedFrame(jpeg: jpeg,
                             width: UInt16(CVPixelBufferGetWidth(pixelBuffer)),
                             height: UInt16(CVPixelBufferGetHeight(pixelBuffer)))
    }
}
