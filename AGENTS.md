# Agent Notes

## Project Shape

- `Sources/CAMouflage` is the simulator-side Swift package library (Objective-C,
  `CMF` prefix). It swizzles AVFoundation capture APIs at `+load` and talks to a
  provider over two Unix domain sockets: newline-delimited JSON control on
  `/tmp/camouflage.sock` (`CMFConnection`, a direct port of ImpossiBLE's
  `CBSConnection`) and binary frames on `/tmp/camouflage-frames.sock`
  (`CMFFrameStream`). The control socket opens lazily on first capture-API use.
- `Sources/MockApp` builds `CAMouflage-Mock.app`, the host-side menu bar
  provider (own `Package.swift`, built via `swift build` through the Makefile).
  `MockCameraServer` owns the control socket, `FrameServer` the frame socket,
  `FrameProducer` renders fixtures (test pattern / image / movie → JPEG).
- **Passthrough lives in the same app**, not a separate helper. In passthrough
  mode `FrameServer` serves frames from a shared `CameraCaptureSource` (a real
  `AVCaptureSession` on a selected Mac camera → JPEG) instead of a fixture.
  `CameraCatalog` enumerates Mac video devices, tracks camera authorization, and
  persists the picked device. The simulator library is unchanged and
  source-agnostic: it just reads JPEG frames, so mock and passthrough are
  byte-identical on the wire. The `Sources/Helper/` design in PLAN.md §2 is
  superseded — do not build it unless mock and passthrough must run at once.
- `SampleApp` is an xcodegen project (`project.yml`; the `.xcodeproj` is
  generated and gitignored). It shows a preview layer plus a frame counter fed
  by `AVCaptureVideoDataOutput`.
- Sibling project: `~/Documents/late/ImpossiBLE` — same architecture for
  CoreBluetooth. When in doubt about a pattern, look there.

## Wire Protocol

Control messages (client → provider): `hello {clientVersion, bundleId, pid}`,
`listDevices`, `startSession {sessionId, deviceId, maxFps}`, `stopSession
{sessionId}`. Provider → client: `didListDevices {devices: [{id, name,
position}]}`, `didStartSession {sessionId, ok}`, `didStopSession`,
`connectionRejected {code: clientBusy}` for a second client.

Frame plane: client connects, sends one JSON hello line `{"sessionId": n}`,
then reads binary frames. **The 32-byte little-endian header is a cross-target
contract**: `CMFFrameHeader` in `CMFFrameStream.m` and `pushFrame(to:)` in
`FrameServer.swift` must stay byte-identical (magic `CMF1`, payloadLength,
sessionId, width, height, pixelFormat `jpeg`, rotation, mirrored, reserved,
ptsMicros). The pixel-format tag is the seam for a future zero-copy upgrade.

## Invariants and Gotchas

- **Proxy objects never run AVFoundation initializers or deallocs.**
  `CMFCaptureDevice`, `CMFDiscoverySession`, `CMFCaptureConnection`, and
  shimmed `AVCaptureDeviceInput` instances are alloc'd, initialized at the
  NSObject level (`CMFNSObjectInit`), and kept alive forever via
  `CMFImmortalize` — their superclass ivars are zeroed, so a real dealloc could
  crash on CFRelease(NULL). Do not "fix" the leak.
- **`AVCaptureSession` outputs are always bookkept locally** (never handed to
  the real backend); inputs are bookkept only when shimmed, so real audio
  inputs still work. The `inputs`/`outputs` getters merge orig + local arrays.
- **`startRunning` never calls the original implementation** — the simulator
  backend would log errors and deliver nothing. `running` is an associated
  flag with manual KVO will/did calls plus the Did{Start,Stop}Running
  notifications.
- The preview layer trick: `AVCaptureVideoPreviewLayer` gets a hosted
  `AVSampleBufferDisplayLayer` sublayer; frames carry the
  `DisplayImmediately` attachment because there is no synchronized timebase.
- Sessions do not resume after a provider restart: the library reconnects and
  re-lists devices, but a running `AVCaptureSession` must be restarted by the
  app (PoC limitation; on the roadmap).
- The mock app persists `ProviderMode`, `ServerEnabled`, `Fixture` (JSON data),
  and `PassthroughDeviceID` (the selected Mac camera's `uniqueID`) in
  `de.vanille.camouflage-mock` defaults — headless testing can seed these with
  `defaults write` before launch. `ProviderMode` is now the single source of
  truth for whether the provider runs: `StatusBarController.applyMode()` starts
  the sockets for both `mock` and `passthrough` and stops them for `off`.
- **Passthrough invariants.** One `CameraCaptureSource` is shared across both
  virtual cameras (Continuity Camera refuses concurrent sessions on the same
  device). The real camera only runs while at least one simulator stream is live
  (`FrameServer.updateCameraRunState()`), so the green camera LED honestly
  tracks "a sim app is streaming," not "passthrough is selected." Switching to
  Mock (`useFixture`) tears the camera down; the `Fixture` didSet is ignored
  while in passthrough. The advertised device list stays the two `cmf-back` /
  `cmf-front` facades in both modes so `AVCaptureDevice.default(...back)` keeps
  resolving — the selected real camera feeds both. Passthrough needs
  `NSCameraUsageDescription` (in `Resources/Info.plist`) and a one-time TCC
  grant; ad-hoc dev builds get a fresh identity each rebuild, so macOS re-prompts.
- **Hardened Runtime needs the camera entitlement.** Release builds are
  Developer ID signed with `--options runtime` (`make mock`), and the Hardened
  Runtime *blocks* `AVCaptureSession` unless
  `com.apple.security.device.camera` is in `Resources/entitlements.plist` —
  `NSCameraUsageDescription` is necessary but not sufficient. Symptom when it is
  missing: passthrough silently fails ("permission not granted") on the installed
  release app while `make mock-debug` (ad-hoc, no Hardened Runtime, entitlement
  not enforced) works fine — the classic "works in debug, denied in release" trap.

## Backlog

### Quiet the `CVPixelBufferCreate returned err -6680` log spam

**Symptom.** The simulator app's console logs, once per frame:
`CVPixelBufferCreate returned err -6680. width 1920, height 1080, pixel format
RGBA, options [ExtendedPixelsRight = 0, ExtendedPixelsBottom = 0,
BytesPerRowAlignment = 64]`. Frames render correctly regardless.

**It is noise, not breakage.** `-6680` is `kCVReturnInvalidPixelFormat`. The
buffer we ask for (`cmf_pixel_buffer_from_jpeg` in `CMFFrameStream.m`) is
`kCVPixelFormatType_32BGRA` with `kCVPixelBufferIOSurfacePropertiesKey: @{}`. If
*our* `CVPixelBufferCreate` were failing we would return `NULL`, log "dropping
undecodable frame", and show no video — since video plays, our create succeeds.
The `-6680` is CoreVideo's *internal* IOSurface allocation attempt (forced by the
IOSurface-properties key) complaining under the simulator's IOSurface path before
it falls back to a working allocation. Confirm before fixing: temporarily drop the
IOSurface key and see whether the log stops (and whether the hosted
`AVSampleBufferDisplayLayer` still renders — it may need IOSurface-backed buffers).

**Fix direction (no custom JPEG codec needed).** The error is about buffer
*allocation*, not JPEG *decoding*, so a hand-rolled high-performance JPEG routine
is the wrong tool here. Do, in order:
1. **Reuse a `CVPixelBufferPool`** keyed by `(width, height)` instead of
   `CVPixelBufferCreate` per frame. This is already the outstanding Phase 3 TODO
   (PLAN.md §7: "No `CVPixelBufferPool` reuse"). The pool is created once with the
   attributes CoreVideo actually accepts on the simulator, so the failed-attempt
   log stops *and* per-frame allocation disappears. Biggest single win.
2. **Pin the pool's pixel-buffer attributes** to what the display path wants
   (`kCVPixelBufferPixelFormatTypeKey`, and only the IOSurface properties that the
   simulator's IOSurface allocator accepts — `BytesPerRowAlignment` etc. surfaced
   in the log are the knobs to get right).
3. Optionally decode straight into the pooled buffer to drop the
   `CGImage → CGBitmapContext → pixel buffer` copy.

**When JPEG throughput actually becomes the bottleneck** (profile first — ImageIO's
`CGImageSource` decode is fine for 1080p30 today), the escalation path is *not* a
custom decoder but either VideoToolbox's hardware JPEG (`VTDecompressionSession`
with `kCMVideoCodecType_JPEG`, hardware-backed on Apple Silicon) or skipping JPEG
entirely via the already-designed v2 zero-copy frame plane (IOSurface /
`SCM_RIGHTS` fd-passing — the pixel-format tag in the frame header is the seam).
Neither is warranted until pooling is in place and numbers say otherwise.

## Photo & metadata (library-side)

- **Photo capture** swizzles `-[AVCapturePhotoOutput capturePhotoWithSettings:
  delegate:]` into a control-plane round-trip (`capturePhoto` →
  `didCapturePhoto`, JPEG base64 in JSON on the control socket — the frame socket
  stays stateless). `CMFPhoto` and `CMFResolvedPhotoSettings` (in `CMFProxies`)
  are accessor-override-only shims alloc'd at the NSObject level and immortalized
  like the other proxies. The delegate choreography (willBegin → willCapture →
  didFinishProcessing → didFinishCapture) is replayed on a private serial queue.
- **Metadata / barcodes** are fully in-process (`CMFMetadata.m`): the frame
  router calls `CMFMetadataProcessFrame` for each `AVCaptureMetadataOutput`,
  which runs `VNDetectBarcodesRequest` off-thread (throttled ~10 Hz) and emits
  `AVMetadataMachineReadableCodeObject` shims. No provider round-trip.
- **Two simulator-Vision gotchas, both handled in `cmf_detect_codes`:** the
  default barcode detector fails on the simulator with *"Could not create
  inference context"*, so we pin `VNDetectBarcodesRequestRevision1` (classical,
  no ML) when supported; and Vision's `CVPixelBuffer` path also trips there, so
  we hand it a `CGImage` decoded through a **software** `CIContext`. Both are
  needed — dropping either regresses to zero detections on the simulator.
- **The metadata delegate selector is `captureOutput:didOutputMetadataObjects:
  fromConnection:`** (ObjC), even though Swift presents it as
  `metadataOutput(_:didOutput:from:)` — an API-notes rename. Use the ObjC name in
  `respondsToSelector:`/dispatch.

## Gotchas when running the SampleApp

- **Regenerate after source changes.** `SampleApp.xcodeproj` is generated and
  gitignored; run `xcodegen generate` (and a clean build) after pulling changes
  that touch the SampleApp or the library, or a stale incremental build can run
  old/broken code.
- **Blank screen at launch = no provider running (usually).** The SampleApp
  shows a black "No camera — is the CAMouflage mock app running?" placeholder
  until the first frame arrives. Start the mock app (Mock or Passthrough) and
  frames appear. On some iOS Simulator runtimes (seen on the iOS 26/27 betas) a
  freshly launched app with no frames yet can get stuck showing the blank launch
  image until something forces a window re-layout (a rotation, a tap, or the
  first frame). It is a simulator compositing quirk, not an app bug — the moment
  frames flow (provider running) or the user interacts, the UI appears.

## Validation

```bash
make mock && open CAMouflage-Mock.app          # provider (Mock mode in panel)
cd SampleApp && xcodegen generate
xcodebuild -project SampleApp.xcodeproj -scheme SampleApp \
  -destination 'platform=iOS Simulator,id=<UDID>' build
xcrun simctl install <UDID> <built .app> && xcrun simctl launch <UDID> de.vanille.camouflage-sample
xcrun simctl io <UDID> screenshot check.png    # expect fixture + rising frame counter
```

The library alone builds with
`xcodebuild -scheme CAMouflage -destination 'generic/platform=iOS Simulator' build`.
