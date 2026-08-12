# CAMouflage — Implementation Plan

> **Status (2026-08-12): proof of concept complete and validated, now with
> live passthrough.** A real Mac camera (built-in, external UVC, or Continuity
> Camera) forwards into the simulator through the same sockets that serve mock
> fixtures. See [§7 Status](#7-status-2026-08-12) for what exists versus what is
> planned; AGENTS.md records the invariants the implementation established.

**Use a real camera from the iOS Simulator.**

The iOS Simulator has no camera: `AVCaptureDevice` discovery returns nothing, sessions
never produce frames, and every scan/photo/video flow is untestable without a device.
CAMouflage disguises a fake capture pipeline as the real one — transparently bridging
AVFoundation capture from a simulated app to actual camera hardware on the host Mac,
or to configurable mock fixtures.

Sibling project to ImpossiBLE. Same philosophy, same architecture, same integration
story: add a local Swift package, build, run. No `DYLD_INSERT_LIBRARIES`, no system
extension, no code changes in the app under test.

---

## 1. Product Definition

### What it does

- **Passthrough mode** — the simulator app sees the Mac's cameras (FaceTime HD,
  external UVC webcams, and **Continuity Camera**, i.e. a real iPhone camera feeding
  the simulator) as native `AVCaptureDevice`s.
- **Mock mode** — the simulator app sees virtual cameras serving static images,
  looping video files, generated test patterns, or generated QR/barcode frames.
- **Client-supplied fixtures** — a UI test uploads its own mock configuration
  ("serve this QR code as the back camera") and asserts the scan flow end-to-end.

### v1.0 scope (mirrors ImpossiBLE's "central role only" discipline)

In scope:

- `AVCaptureDevice` discovery, default-device lookup, authorization
- `AVCaptureSession` lifecycle (add/remove inputs & outputs, start/stop, presets)
- `AVCaptureVideoDataOutput` (live `CMSampleBuffer` delivery on the client's queue)
- `AVCaptureVideoPreviewLayer` (rendering, `videoGravity`, mirroring)
- `AVCapturePhotoOutput` (JPEG/HEIC stills with metadata)
- `AVCaptureMetadataOutput` for machine-readable codes (QR, barcodes) — served
  in-process via Vision, no provider round-trip
- Control surface stubs: focus/exposure/zoom/torch accepted and reported, not enacted

Explicitly out of scope for 1.0 (documented as Limitations, tracked on the roadmap):

- `AVCaptureMovieFileOutput` (1.1: implement in-process via `AVAssetWriter`)
- `UIImagePickerController` camera source
- Audio capture devices — the simulator microphone already works natively;
  CAMouflage intercepts **video devices only** and must not disturb audio paths
- Depth data, multi-cam sessions, face/body metadata, RAW/ProRAW
- `AVCaptureDevice` configuration fidelity (real focus/exposure/zoom effects)

### Prior art and why CAMouflage anyway

iCimulator (typealias, invasive, dormant), iOS-Simulator-Camera-Extend
(`DYLD_INSERT_LIBRARIES` + CoreMediaIO system extension, heavy install), RocketSim
(commercial, closed). None offers the ImpossiBLE combination: link-and-forget SPM
package, transparent swizzling, a real mock story with saved configurations, and
ephemeral client-supplied test fixtures. That combination is the product.

---

## 2. Architecture

Two-process split, identical to ImpossiBLE, plus a dedicated frame plane:

```
┌──────────────────────────────┐          ┌──────────────────────────────────┐
│ iOS Simulator app            │          │ macOS host                       │
│                              │  control │                                  │
│  AVFoundation API surface    │  (NDJSON)│  camouflage-helper.app           │
│  ── swizzled at +load ──►    ◄──────────►  (Passthrough: real AVCapture-   │
│  CMFActivator                │ /tmp/    │   Session on Mac cameras)        │
│                              │ camouflage│         — or —                  │
│  CMFConnection (control)     │ .sock    │  CAMouflage-Mock.app             │
│  CMFFrameStream (frames)     ◄──────────┤  (menu bar app: fixtures,       │
│                              │  frames  │   Off/Mock/Passthrough control)  │
│  CMFProxies (shim objects)   │ (binary) │                                  │
└──────────────────────────────┘ /tmp/    └──────────────────────────────────┘
                                 camouflage-frames.sock
```

### Control plane

Newline-delimited JSON over `/tmp/camouflage.sock` — the exact `CBSConnection`
pattern: lazy connect on first swizzled instantiation, 2-second auto-reconnect,
connection state drives `AVAuthorizationStatus`/device availability, single-client
policy with busy rejection. Port `CBSConnection.m` nearly verbatim.

### Frame plane (the part BLE never needed)

Video bandwidth rules out base64-in-JSON (1080p30 BGRA ≈ 190 MB/s raw). Separate
binary Unix socket `/tmp/camouflage-frames.sock`:

- Client connects once per running capture session, sends a 1-line JSON hello
  (`{"sessionId": …}`), then reads length-prefixed binary frames.
- Frame header (fixed 32 bytes, little-endian): magic `CMF1`, payload length,
  session id, width, height, pixel-format tag, rotation degrees, mirrored flag,
  presentation timestamp (µs).
- Payload v1: **JPEG** (1080p30 ≈ 5–10 MB/s — trivial for a UDS). Decoded on the
  sim side via `CGImageSource` into a reused `CVPixelBufferPool`.
- Payload v2 (post-1.0, internal upgrade, invisible to apps and fixtures):
  fd-passing via `SCM_RIGHTS` + mmap'd ring buffer of raw frames, or shared
  `IOSurface` — the simulator shares the host kernel, so both work. The header's
  pixel-format tag is the seam that makes this a drop-in change.

Photos are *not* frames: photo capture is a control-plane request/response with the
encoded JPEG/HEIC transferred base64 in JSON (single-shot, latency-insensitive,
keeps the frame plane stateless).

### Simulator-side library (`Sources/CAMouflage`, ObjC, `#if TARGET_OS_SIMULATOR`)

| File | Responsibility |
|---|---|
| `CMFActivator.m` | `+load` swizzles, session/device bookkeeping, delegate dispatch |
| `CMFConnection.m/.h` | control socket: lazy connect, reconnect, NDJSON codec |
| `CMFFrameStream.m/.h` | frame socket: read loop, header parse, JPEG→`CVPixelBuffer` |
| `CMFProxies.m/.h` | shim `AVCaptureDevice`, `AVCaptureDeviceFormat`, `AVCapturePhoto` subclasses |
| `CMFPreview.m` | `AVCaptureVideoPreviewLayer` internals (hosted `AVSampleBufferDisplayLayer`) |
| `CMFMetadata.m` | Vision-backed `AVCaptureMetadataOutput` (QR/barcode) |
| `CMFMockConfiguration.m` | the only public API: client-supplied fixtures |
| `include/CAMouflage.h` | umbrella header |

On device builds everything compiles to no-ops, and the public functions return `NO` —
same dual-target story as ImpossiBLE.

### Swizzle surface (what gets intercepted)

| API | Strategy |
|---|---|
| `AVCaptureDevice +devices`, `+devicesWithMediaType:`, `+defaultDeviceWithMediaType:`, `+defaultDeviceWithDeviceType:mediaType:position:` | return `CMFDevice` proxies from the provider's device list (video media types only; audio falls through to the original implementation) |
| `AVCaptureDeviceDiscoverySession +discoverySessionWithDeviceTypes:mediaType:position:` | filter proxy devices by requested types/position |
| `AVCaptureDevice +authorizationStatusForMediaType:`, `+requestAccessForMediaType:` | video → `authorized` / async `YES` (provider connectivity, not TCC, gates reality); audio untouched |
| `AVCaptureDeviceInput +deviceInputWithDevice:error:`, `-initWithDevice:error:` | accept proxy devices, wrap without touching the real backend |
| `AVCaptureSession` add/remove/canAdd inputs & outputs, `startRunning`, `stopRunning`, `sessionPreset`, `beginConfiguration`/`commitConfiguration` | bookkeeping + provider `startSession`/`stopSession`; `running` KVO and `AVCaptureSessionDidStartRunning`/`…DidStopRunning` notifications posted manually |
| `AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:` | store; frames from `CMFFrameStream` become `CMSampleBuffer`s (`CVPixelBufferCreate` + `CMSampleBufferCreateReadyWithImageBuffer` — all public C API) delivered on the stored queue, with frame dropping when the queue is busy (`alwaysDiscardsLateVideoFrames` honored) |
| `AVCaptureConnection` | lightweight shim per input/output pair; `videoRotationAngle` (iOS 17+) / `videoOrientation` (legacy) and `isVideoMirrored` recorded and applied to the frame header interpretation |
| `AVCaptureVideoPreviewLayer` | swizzle `-initWithSession:`/`setSession:` to install a hosted `AVSampleBufferDisplayLayer` sublayer fed from the same frame tap; map `videoGravity`; implement `captureDevicePointOfInterestForPoint:`/`layerRectConverted…` with the known frame geometry |
| `AVCapturePhotoOutput -capturePhotoWithSettings:delegate:` | control-plane request; replay the full delegate choreography (`willBeginCapture` → `willCapturePhoto` → `didFinishProcessingPhoto` → `didFinishCapture`) with a `CMFPhoto : AVCapturePhoto` shim overriding `fileDataRepresentation`, `pixelBuffer`, `cgImageRepresentation`, `metadata`, `resolvedSettings` |
| `AVCaptureMetadataOutput -setMetadataObjectsDelegate:queue:`, `metadataObjectTypes`, `rectOfInterest` | in-process: run `VNDetectBarcodesRequest` on the delivered frames (throttled, off-main), emit `AVMetadataMachineReadableCodeObject` shims with corners/bounds mapped through the preview transform |
| `AVCaptureDevice` focus/exposure/zoom/torch setters, `lockForConfiguration:` | accept, store, reflect in getters, KVO-notify; forwarded to the provider as advisory messages (mock ignores; helper may later apply zoom where macOS supports it) |

The single riskiest shim is `AVCapturePhoto` (no public initializer, KVC-guarded
private ivars possible). Mitigation: the shim only *overrides accessors* on a
subclass alloc'd without designated init (`[CMFPhoto alloc]` + no `init` call into
private state), the same pattern `CBSProxies` uses for `CBPeripheral`. A unit test
instantiates the shim against every new SDK to catch breakage early.

### Helper (`Sources/Helper/CMFHelperMain.m`, single-file clang-built ObjC app)

- Enumerates Mac video devices via `AVCaptureDeviceDiscoverySession`
  (`.builtInWideAngleCamera`, `.external`, `.continuityCamera`) and publishes the
  list (id, localized name, position mapping, supported formats) on client connect
  and on `AVCaptureDeviceWasConnected/Disconnected` notifications.
- Position mapping: the Mac's built-in camera is advertised as the simulator's
  *front* camera; Continuity Camera / external devices as *back* (configurable
  later from the mock app's Passthrough panel).
- Per `startSession`: real `AVCaptureSession` + `AVCaptureVideoDataOutput`,
  JPEG-encodes frames (`VTCompressionSession` or `CIContext` JPEG, whichever
  measures better — decide in Phase 5 with numbers) at the client's negotiated
  resolution/fps cap, streams them on the frame socket.
- Photo requests: `AVCapturePhotoOutput` on the Mac session, encoded result
  returned on the control plane.
- Needs macOS camera TCC consent (`NSCameraUsageDescription`, prompt on first
  session) — parity with the Bluetooth consent the ImpossiBLE helper already needs.
- Writes `/tmp/camouflage-passthrough-activity.json` (which device is live, fps,
  client app) for the mock app's Passthrough panel — same snapshot pattern.

### Mock app (`Sources/MockApp`, SwiftPM, AppKit `StatusBarController` + SwiftUI content)

Direct port of the ImpossiBLE-Mock shell (status item, persistent panel,
Off / Mock / Passthrough segmented control, mutual-exclusion daemon management,
launch-at-startup, state persistence, activity-flash icon). New content:

- **Fixture types** (a configuration = named list of virtual camera devices, each
  with position front/back and a source):
  - static image (PNG/JPEG/HEIC, drag & drop)
  - looping video file (mp4/mov, decoded with `AVAssetReader`)
  - generated test pattern (SMPTE bars + timestamp burn-in — instantly recognizable
    as "the mock is live")
  - generated machine-readable code (enter a string, pick QR/Aztec/PDF417/Code128;
    rendered via `CIFilter`, re-rendered when edited)
- **Capture analog**: "Record fixture from Mac camera…" — grab a still or a short
  clip from a real Mac camera straight into a new fixture (the spiritual sibling of
  ImpossiBLE's BLE advertisement capture).
- Editor: device list → per-device source editor. Much shallower than the GATT tree
  editor — one screen per device, no nested service/characteristic hierarchy.
- Stock configurations: "QR badge", "SMPTE pattern", "Portrait selfie",
  "Conference room loop".
- Icon: camera glyph; strikethrough when off, plain when passthrough, dot-badged
  when mocking, flash on frame traffic (throttled to ~2 Hz so 30 fps doesn't strobe).

### Wire protocol (control plane)

Same envelope style as ImpossiBLE (`type` + payload keys). Core messages:

```
client → provider
  hello                     {clientVersion, bundleId}
  listDevices               {}
  startSession              {sessionId, deviceId, width, height, maxFps}
  stopSession               {sessionId}
  capturePhoto              {sessionId, requestId, format: "jpeg"|"heic", flashMode}
  setControl                {sessionId, control: "zoom"|"focusPOI"|…, value}   // advisory
  setMockConfiguration      {configuration: {…}}                                // fixtures
  clearMockConfiguration    {}

provider → client
  didListDevices            {devices: [{id, name, position, deviceType, formats}]}
  devicesChanged            {devices: […]}
  didStartSession           {sessionId, ok, error?}
  didStopSession            {sessionId}
  didCapturePhoto           {requestId, ok, dataBase64, metadata, error?}
  didSetMockConfiguration   {ok, error?}          // fail loudly, like ImpossiBLE
  busy                      {}                    // second client rejected
```

Version pinning caveat carries over verbatim: pin the provider alongside the
library; unknown message types are ignored, not errored.

### Client-supplied configurations (public API, `CMFMockConfiguration.m`)

```swift
import CAMouflage

CAMouflageIsProviderConnected()                    // waits briefly, safe at startup
CAMouflageSetMockConfiguration(configurationData)  // ephemeral, visible, verified
CAMouflageClearMockConfiguration()
```

Same three invariants as ImpossiBLE, enforced from day one:
ephemeral (never persisted into the user's saved configurations, cleared on both
edges of the connection), visible (panel shows the served client configuration
read-only), verified (`didSetMockConfiguration` reports decode failures).

Configuration JSON shape (same file format the mock app saves/exports):

```json
{
  "id": "…", "name": "QR badge",
  "devices": [
    { "id": "…", "name": "Back Camera", "position": "back",
      "source": { "kind": "machineCode", "symbology": "qr", "payload": "https://…" } }
  ]
}
```

`source.kind` ∈ `image` (base64 or file reference for saved configs), `video`,
`testPattern`, `machineCode`.

---

## 3. Repository Layout

```
CAMouflage/
├── Package.swift               # library only, iOS 15+, links AVFoundation
├── Makefile                    # ImpossiBLE Makefile ported: help default,
│                               # helper/mock/install/run/stop/watch/notarize,
│                               # git-count build number, codesign fallbacks
├── README.md                   # logo, pitch, quick start, modes, limitations
├── AGENTS.md                   # project shape + invariants (grow as they appear)
├── PLAN.md                     # this file
├── LICENSE                     # MIT
├── Sources/
│   ├── CAMouflage/             # simulator-side ObjC library (CMF prefix)
│   ├── Helper/                 # CMFHelperMain.m, Info.plist, entitlements.plist
│   └── MockApp/                # own Package.swift, Server/ Models/ Views/ Resources/
├── Tests/CAMouflageTests/      # protocol codec, frame header, shim smoke tests
└── SampleApp/                  # iOS demo: preview + QR scan + photo capture
```

Conventions that apply throughout: English comments (WHY only), no attribution
trailers anywhere, `CFBundleVersion` from `git rev-list --count HEAD`,
`.DEFAULT_GOAL := help`, guard-based early exit, 4-space indented `case`s,
one SwiftUI view per file, `Cornucopia.Core.Logger` in the Swift mock app
(the ObjC library/helper use `os_log` like ImpossiBLE's, wrapped in a
`CMFLog` macro that is compiled out unless `DEBUG`).

---

## 4. Phases

Each phase ends buildable and demonstrable; validation listed per phase.

### Phase 0 — Scaffold (½ day)
Repo layout above; Makefile ported from ImpossiBLE with names swapped
(`camouflage-helper`, `CAMouflage-Mock`, sockets, zips); empty-but-linking library
with `+load` logging under `TARGET_OS_SIMULATOR`; SampleApp shell.
**Validate:** `make` prints help; `swift build` (library) succeeds for iOS
simulator and device destinations; SampleApp runs in the simulator and logs the
activation line.

### Phase 1 — Control + frame transport (1–2 days)
Port `CBSConnection` → `CMFConnection` (lazy connect, reconnect, NDJSON).
Implement `CMFFrameStream` reader and the frame header codec. Helper skeleton:
accepts one client, answers `listDevices` with a hardcoded device, streams a
generated gradient as JPEG frames on request.
**Validate:** unit tests for header encode/decode round-trip and NDJSON framing;
a throwaway harness in SampleApp prints received frame dimensions/fps.

### Phase 2 — Device discovery & authorization (1 day)
Swizzle the discovery/default-device/authorization surface onto proxy devices
built from `didListDevices`; `devicesChanged` handling; audio passthrough
untouched.
**Validate:** SampleApp lists front/back cameras via
`AVCaptureDeviceDiscoverySession`; `requestAccess` resolves `true`; with no
provider running, discovery is empty and authorization still resolves (documented:
device availability, not authorization, models provider state).

### Phase 3 — Session + VideoDataOutput (2–3 days) — *the heart*
Session bookkeeping and lifecycle messages; `CVPixelBufferPool`-backed JPEG
decode; `CMSampleBuffer` construction with proper timing; delegate delivery on the
client queue with late-frame dropping; `running` KVO + session notifications;
connection shims with rotation/mirroring bookkeeping.
**Validate:** SampleApp renders live frames into a plain `CALayer` at target fps;
Instruments confirms no per-frame allocations beyond the pool; stopping the helper
mid-stream stops delivery and flips session state (parity with ImpossiBLE's
disconnect fidelity).

### Phase 4 — Preview layer (1–2 days)
`AVCaptureVideoPreviewLayer` swizzle hosting an `AVSampleBufferDisplayLayer`;
`videoGravity` mapping; mirroring for front devices; point/rect conversion using
known frame geometry.
**Validate:** SampleApp switches to a stock `AVCaptureVideoPreviewLayer` and looks
correct in resize/aspect/aspectFill, portrait and landscape, light and dark chrome.

### Phase 5 — Helper passthrough (2 days)
Real device enumeration incl. Continuity Camera; real capture session per client
session; JPEG encoder choice measured (`VTCompressionSession` vs `CIContext`);
resolution/fps negotiation; TCC prompt flow; activity snapshot file; hot
plug/unplug → `devicesChanged`.
**Validate:** SampleApp shows the Mac camera live; unplugging an external webcam
mid-session ends that session cleanly; `make watch` loop stays usable.

> **Delivered differently (2026-08-12): passthrough lives inside the mock app,
> not a separate helper.** The simulator library is source-agnostic — it only
> ever reads JPEG frames off the frame socket — so passthrough needs no wire or
> library change, only a different frame source on the host. Rather than stand
> up a second process (`camouflage-helper.app`) with its own sockets and its own
> copy of the mutual-exclusion/status machinery, the existing provider grew a
> `CameraCaptureSource` (a shared real-camera `AVCaptureSession` → JPEG) that
> `FrameServer` serves in place of a fixture. One process, one pair of sockets,
> mode switching that is already mutually exclusive by construction. The
> separate-helper design in §2 is superseded for now; revisit it only if
> passthrough and mock ever need to run simultaneously.

### Phase 6 — Mock app (3–4 days)
Port the ImpossiBLE-Mock shell; implement the four fixture sources, the editor,
stock configurations, persistence, "record fixture from Mac camera", mode
mutual-exclusion with the helper.
**Validate:** Off/Mock/Passthrough switching kills/starts the right daemons;
SMPTE + timestamp pattern proves liveness at a glance; video loop plays seamlessly;
panel survives app switches per preference.

### Phase 7 — Photo output (2 days)
`capturePhoto` round-trip in both providers (helper: real `AVCapturePhotoOutput`;
mock: encode current fixture frame at full fixture resolution); `CMFPhoto` shim;
full delegate choreography with correct queue.
**Validate:** SampleApp captures and displays a still from both modes; shim smoke
test (`fileDataRepresentation` non-nil, metadata keys present) runs in CI against
the current SDK.

### Phase 8 — Metadata output via Vision (1–2 days)
In-process `VNDetectBarcodesRequest` on delivered frames, throttled (~10 Hz),
results as `AVMetadataMachineReadableCodeObject` shims with corners mapped through
the preview layer transform; `rectOfInterest` honored.
**Validate:** SampleApp scans a QR fixture end-to-end (the flagship demo);
`metadataObjectTypes` filtering respected; corners visually align with an overlay.

### Phase 9 — Client-supplied fixtures (1 day)
Public API + wire messages + panel banner/read-only list, porting the four
ImpossiBLE invariants; XCTest example in SampleApp: upload QR fixture → assert
scan callback.
**Validate:** the XCTest passes headlessly via `xcodebuild test`; fixture never
appears in saved configurations; disconnect restores the user's selection.

### Phase 10 — Polish & release (2 days)
README with screenshots + logo (camouflage-pattern camera motif), Limitations and
Roadmap sections; AGENTS.md invariants; notarization targets exercised; version
pinning note; ChangeLog; final full-surface pass (all Makefile targets, both
modes, SampleApp flows).

Post-1.0 backlog: `AVAssetWriter`-based `MovieFileOutput`, zero-copy frame plane
(fd-passing/IOSurface), `UIImagePickerController`, configurable position mapping,
scripted fixture sequences (timed frame scripts for testing scan-retry UX),
multi-client.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `AVCapturePhoto`/metadata-object shims break on a new SDK | photo/scan callbacks crash or return nil | accessor-override-only shims (no private ivar writes); dedicated smoke tests run per SDK bump; degrade to documented limitation, never crash |
| Preview layer internals resist hosting a display layer | no drop-in preview | fallback: swizzle only geometry/gravity APIs and render via our own sublayer tree — the layer *is* ours after `setSession:`, Apple's pipeline never attaches in the simulator |
| Frame-plane throughput or decode cost too high on low-end Macs | dropped frames, hot CPU | JPEG quality/fps negotiation knobs; pixel-buffer pool; v2 zero-copy path already designed into the header format |
| Session/connection API breadth (KVO, notifications, presets) | subtle app breakage | implement the observable contract (KVO + notifications + getters) first, breadth later; SampleApp exercises the common recipes (Apple's AVCam patterns) as the acceptance bar |
| Simulator TCC differences across Xcode versions | authorization swizzle mismatch | authorization is fully swizzled for video — we never reach real TCC; covered by a unit test |
| Two daemons, two sockets, stale state | "why is there no image" support burden | mutual exclusion + status parity with ImpossiBLE; SMPTE test pattern as instant liveness proof; `make status`/`log` targets from day one |

---

## 6. Success Criteria (v1.0)

1. Apple's AVCam-style sample code runs unmodified in the simulator with live
   Mac-camera video, working preview, and photo capture.
2. A QR-scan view controller scans a mock fixture with zero app changes.
3. An XCTest uploads a client fixture and asserts the scan callback — headless.
4. Device builds are byte-for-byte no-ops (no socket, no swizzle, `NO` returns).
5. ImpossiBLE and CAMouflage READMEs side by side read as siblings.

---

## 7. Status (2026-08-12)

The proof of concept was validated end-to-end on the iPhone 16 Pro and
iPhone 17 simulators: device discovery, stock `AVCaptureVideoPreviewLayer`
rendering, and `AVCaptureVideoDataOutput` delegate delivery, with all three
fixture types **and live passthrough** from a real Mac camera (validated
against a Logitech UVC webcam at 1920×1080). Validation evidence:
`screenshot-poc.png` in the repo root.

| Phase | State | Notes |
|---|---|---|
| 0 — Scaffold | ✅ done | No logo yet; no `Tests/` directory yet |
| 1 — Transport | ✅ done | Header codec unit tests still owed |
| 2 — Discovery & authorization | ✅ done | Audio APIs pass through untouched |
| 3 — Session + VideoDataOutput | ✅ done (PoC level) | No `CVPixelBufferPool` reuse, no late-frame dropping yet |
| 4 — Preview layer | ✅ done (PoC level) | Gravity + layout work; point/rect conversion not implemented |
| 5 — Passthrough | ✅ done (in mock app) | Real camera enumeration (built-in/external/Continuity/Desk View), selectable source, live device switching, TCC prompt, camera runs only while a client streams. Integrated into the mock app rather than a separate helper (see Phase 5 note). Missing: fps/resolution negotiation, activity snapshot file, JPEG-encoder measurement |
| 6 — Mock app | 🟡 PoC subset | Test pattern / image / movie fixtures, passthrough source picker, live switching, persistence. Missing: per-device fixtures, stock configurations, capture-from-camera, launch-at-startup |
| 7 — Photo output | ⬜ not started | `CMFPhoto` shim design in §2 |
| 8 — Metadata via Vision | ⬜ not started | |
| 9 — Client-supplied fixtures | ⬜ not started | `CAMouflageIsProviderConnected()` already public |
| 10 — Polish & release | 🟡 partial | README, AGENTS.md, screenshot exist |

Known PoC limitations beyond the table:

- A running `AVCaptureSession` does not resume after a provider restart; the
  app must call `stopRunning`/`startRunning` again. (This is why a SampleApp
  left running while the mock app is relaunched shows "no frames yet" until the
  app restarts its session — it is not a passthrough bug.)
- `MovieProducer` uses the deprecated synchronous `tracks(withMediaType:)`
  loading (deliberate — it runs on the frame server's I/O queue); migrate to
  `loadTracks` when touching that file.
- One source feeds both virtual cameras. Mock fps is capped at 15; passthrough
  runs at 30. Passthrough does not yet honor the client's requested
  resolution/fps — it serves the camera's native format re-encoded as JPEG.
- Passthrough does not mirror or rotate frames; the built-in FaceTime camera is
  served as-is (position mapping and mirroring are on the backlog).
- The mock app is ad-hoc signed in dev builds, so each rebuild is a new TCC
  identity and macOS re-prompts for camera access on first passthrough use.

### Suggested next steps, in order of leverage

1. **Photo output** (phase 7) — the most-requested capture flow after preview.
2. **Metadata via Vision** (phase 8) — unlocks QR-scan testing, the killer demo.
3. **Client-supplied fixtures** (phase 9) — small, and makes UI tests possible.
4. **Passthrough polish** (phase 5 tail) — position mapping (built-in → front,
   Continuity/external → back), mirroring for front devices, resolution/fps
   negotiation, and reflecting the real device name in the advertised list.
