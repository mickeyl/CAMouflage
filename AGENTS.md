# Agent Notes

## Project Shape

- `Sources/CAMouflage` is the simulator-side Swift package library (Objective-C,
  `CMF` prefix). It swizzles AVFoundation capture APIs at `+load` and talks to a
  provider over two Unix domain sockets: newline-delimited JSON control on
  `/tmp/camouflage.sock` (`CMFConnection`, a direct port of ImpossiBLE's
  `CBSConnection`) and binary frames on `/tmp/camouflage-frames.sock`
  (`CMFFrameStream`). The control socket opens lazily on first capture-API use.
- `Sources/CAMouflage-Mock` builds `CAMouflage-Mock.app`, the host-side menu bar
  provider (own `Package.swift`, built via `swift build` through the Makefile).
  It has two targets: **`CAMouflageProviderKit`** (library product
  `ProviderKit/` — camera server, frame plane, fixtures, catalog, panel view;
  this is what the Simsalabim suite app will embed) and the thin
  **`CAMouflage-Mock`** executable (`App/` — app lifecycle plus the shell
  wiring in `StatusBarController`). The ProviderKit's public surface:
  `MockCameraServer` (facade with `transport` and the frame-traffic pulse),
  `CameraCatalog`, and `MenuContent`; everything else is internal.
  The control-plane transport is SimBridgeKit's `ProtocolServer`
  (`MockCameraServer.transport`, URL dependency on
  github.com/mickeyl/SimBridgeKit) — socket lifecycle, NDJSON framing, the
  `hello` handshake, last-connection-wins takeover, client-socket hardening
  (SO_NOSIGPIPE + send timeout: a client that stops reading is disconnected
  instead of wedging the I/O queue), and the socket-ownership guard (a second
  provider instance shows Blocked instead of stealing the socket).
  `MockCameraServer` is the domain layer on top; its handlers run on the
  transport's I/O queue, which also guards its mutable state. `FrameServer`
  owns the frame socket, `FrameProducer` renders fixtures (test pattern /
  image / movie / generated machine code → JPEG).
- **Passthrough lives in the same app**, not a separate helper. In passthrough
  mode `FrameServer` serves frames from a shared `CameraCaptureSource` (a real
  `AVCaptureSession` on a selected Mac camera → JPEG) instead of a fixture.
  `CameraCatalog` enumerates Mac video devices, tracks camera authorization, and
  persists the picked device. The simulator library is unchanged and
  source-agnostic: it just reads JPEG frames, so mock and passthrough are
  byte-identical on the wire. The `Sources/Helper/` design in PLAN.md §2 is
  superseded — do not build it unless mock and passthrough must run at once.
- `SampleApp` is an xcodegen project (`project.yml`; the `.xcodeproj` is
  generated and gitignored). It shows preview/photo/metadata flows plus a frame
  counter, and its test target owns a generated QR fixture end-to-end.
- Sibling project: `~/Documents/late/ImpossiBLE` — same architecture for
  CoreBluetooth. When in doubt about a pattern, look there.

## Wire Protocol

Control messages (client → provider): `hello {clientVersion, bundleId, pid}`,
`listDevices`, `startSession {sessionId, deviceId, maxFps}`, `stopSession
{sessionId}`, `capturePhoto {sessionId, requestId, format}`,
`setMockConfiguration {configuration}`, `clearMockConfiguration`. Provider →
client: `didListDevices {devices: [{id, name, position}]}`, `devicesChanged`,
`didStartSession {sessionId, ok}`, `didStopSession`, `didCapturePhoto {requestId,
ok, width, height, dataBase64}`, `didSetMockConfiguration {ok, error?}`,
`connectionRejected {code: clientBusy}`.

**Single client, last-connection-wins.** The provider serves one simulator at a
time, but a new connection *takes over* rather than being rejected: on connect it
sends `connectionRejected {clientBusy}` to the **previous** client (whose library
then stops auto-reconnecting) and evicts it, then accepts the newcomer. This is
what makes relaunching the app, or switching between simulators, "just work" —
the freshly launched one wins. To use an older simulator again, relaunch its app.
Since the SimBridgeKit adoption this lives in `ProtocolServer`; async work that
outlives a message handler (e.g. frame-stream authorization) must capture
`MockCameraServer.connectionEpoch` and re-check it on completion, because the
client fd is no longer exposed.

All Unix socket creation paths set `SO_NOSIGPIPE` (the control plane via
SimBridgeKit, the frame plane and the simulator side locally). Keep it that way:
takeover/disconnect races routinely make a final write hit a closed peer, and
the default SIGPIPE action would kill the whole provider or client process
instead of returning a write error. The control plane additionally inherits
SimBridgeKit's send-timeout discipline (a non-reading client is disconnected
instead of wedging the I/O queue); the frame plane has no equivalent yet — its
writes run on the frame server's own queue, not the control queue.

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
- Running sessions automatically send `startSession` again after the control
  socket reconnects and the provider returns its fresh device list. Keep the
  existing session id: the matching frame stream was stopped on disconnect and
  is recreated after `didStartSession`.
- JPEG decode buffers come from a `CVPixelBufferPool` keyed by dimensions. Its
  attributes deliberately omit `kCVPixelBufferIOSurfacePropertiesKey`: forcing
  an IOSurface on affected simulator runtimes causes harmless but per-frame
  `-6680` allocation noise before CoreVideo falls back. The hosted display layer
  accepts the pooled CPU buffers.
- `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` is honored at the
  delegate boundary. With it enabled, at most one callback per output is queued
  or executing.
- The mock app persists `ProviderMode`, `ServerEnabled`, `Fixture` (JSON data),
  and `PassthroughDeviceID` (the selected Mac camera's `uniqueID`) in
  `de.vanille.camouflage-mock` defaults — headless testing can seed these with
  `defaults write` before launch. `ProviderMode` is the single source of
  truth for whether the provider runs: the mode transition (SimBridgeShell's
  `ModeTransitionController`, wired in `StatusBarController`) starts the
  sockets for both `mock` and `passthrough` and stops them for `off`.
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

## Client-supplied fixtures

- `CAMouflageSetMockConfiguration(NSData *)` accepts a JSON object containing a
  named device list and per-device sources. Supported source kinds are
  `testPattern`, `image` (`dataBase64` or host `path`), `movie` (host `path`),
  and `machineCode` (`qr`, `aztec`, `pdf417`, `code128` plus `payload`).
- The provider override is connection-scoped: never write it to `UserDefaults`,
  show it read-only in the panel, clear it on disconnect/takeover, and restore
  the current Mock/Passthrough selection. The simulator library retains the JSON
  only for the life of its process so it can resend it after a provider restart.
- Dynamic client device ids are valid session targets. `FrameServer` therefore
  records `sessionId → deviceId` during authorization and selects the matching
  producer per stream. Keep authorization completion ahead of `didStartSession`
  so the frame socket cannot race the control-plane acknowledgement.

## Backlog

- Decode still takes the `CGImage → CGBitmapContext → pooled pixel buffer` copy.
  Profile before escalating; the designed next options are VideoToolbox JPEG or
  the v2 zero-copy frame plane via fd passing/IOSurface.

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

# With CAMouflage-Mock running, validates client-owned QR fixtures end-to-end:
xcodebuild -project SampleApp.xcodeproj -scheme SampleAppTests \
  -destination 'platform=iOS Simulator,id=<UDID>' test
```

The library alone builds with
`xcodebuild -scheme CAMouflage -destination 'generic/platform=iOS Simulator' build`.
