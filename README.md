# Record TimeLapse

A lightweight macOS menu-bar app (Apple Silicon, macOS 14–27) that records **long screen time-lapses** — 12, 24, 48 hours — and **doesn't crash on save**.

Fully controlled from the menu bar. Capture is **event-driven** (`SCStream` with `minimumFrameInterval`): WindowServer delivers a frame only when the screen actually changed, so static periods cost neither battery nor disk. Encoding is **streaming and zero-copy**, so memory stays constant regardless of recording length.

---

## Why the old app crashed the Mac and this one doesn't

`Screen-TimeLapse-Lite` buffered **every frame in RAM** and encoded the video at the very end. 12 hours at one frame/second ≈ 43,200 uncompressed 1080p frames ≈ **hundreds of gigabytes of RAM** → freeze and crash. Its "save every 2 hours" workaround left you with a pile of files.

This pipeline is different — **O(1) memory and zero-copy**:

```
SCStream (minimumFrameInterval = interval, 420v, idle-suppression)
  → a frame arrives ONLY when the screen changed (IOSurface, no copies)
  → adaptor.append(buffer) → AVAssetWriter (hardware HEVC) → disk
  → buffer returned to the system immediately
```

Exactly **one** frame is live at any instant, and the CPU never touches the pixels: the GPU captures and converts to YUV, the media engine encodes. Memory for 1 hour and 48 hours is identical. Compressed bytes are written to disk continuously, the same constant-memory model as the reference open-source app [`wkaisertexas/ScreenTimeLapse` (TimeLapze)](https://github.com/wkaisertexas/ScreenTimeLapse).

Time-lapse speed is set **only** by the output frame rate: `video length = frames / FPS`. 12 h at one frame every 2 s, played at 30 fps → **≈ 12-minute clip**, independent of the capture interval.

---

## Build & run

Requires Xcode / Command Line Tools (Swift 6+).

```bash
cd "Record Time Laps"
./Scripts/build_app.sh --install   # builds, signs, and installs to /Applications
```

After that it launches like any normal app — **⌘Space → "Record TimeLapse"** (Spotlight) or from the Applications folder. Without `--install` the build stays in `dist/RecordTimeLapse.app`.

First launch: **System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording** → enable Record TimeLapse → reopen the app. The icon appears at the right of the menu bar (a red dot while recording).

> **About signing.** The script signs with a stable certificate (`Apple Development` / `Developer ID`) that it auto-detects. This matters: the Screen Recording permission is tied to (bundle id + certificate). Ad-hoc signing (`-`) changes the hash on every build and **resets the permission** — the script warns you if no stable certificate is found. You can pass your own via `SIGN_ID="..." ./Scripts/build_app.sh`.

Tests: `swift test`. Open in Xcode: `open Package.swift`.

---

## Controls (menu bar)

- **Start / Stop & Save** — start, and finalize by stitching segments into a single file.
- **Pause / Resume** — manual pause.
- Live stats: frames, recording time, projected video length, size on disk.
- **Reveal Last Video**, **Open Output Folder**, **Settings…**, **Quit** (finalizes the recording cleanly before exit).

Finished clips: `~/Movies/RecordTimeLapse/` (folder configurable in Settings).

---

## Settings

**Capture**
- *Capture every* — capture interval: 0.5 / 1 / 2 / 5 / 10 / 30 / 60 s.
- *Display* — which monitor (main by default).
- *Resolution* — cap on the long edge (2560 by default; GPU downscaling saves battery and space).
- *Show mouse cursor*.

**Output**
- *Output frame rate* — 15 / 24 / 30 / 60 fps (sets the time-lapse speed).
- *Codec* — HEVC (small files) or H.264 (maximum compatibility).
- *Checkpoint every* — how often (minutes of real time) the recording is sealed into a standalone checkpoint file; on a crash everything up to the last checkpoint is recovered automatically. The output is always a single file.
- *Save to* — output folder.

**General**
- *Pause when the screen sleeps or locks* — pause on sleep/lock (on by default) so no black frames are recorded. The video continues seamlessly.
- *Keep Mac awake while recording* — record continuously through idle (heavier on battery; off by default).
- *Launch at login*.

---

## Robustness over 12+ hours

- **Segments.** Every N minutes the writer rotates: a finished segment is a valid standalone file. A crash loses at most the last unfinished segment.
- **Movie fragments.** `movieFragmentInterval = 10 s` keeps even an interrupted `.mov` playable.
- **Recovery.** On launch `RecoveryManager` finds the segments of an interrupted session in `Application Support/RecordTimeLapse/sessions` and stitches them into `Recovered ….mov`.
- **Sleep / lock.** `NSWorkspace` + DistributedNotificationCenter → auto pause/resume. The timeline is frame-index based, so the video continues with no gap after a pause.
- **Display changes.** Unplug a monitor / change scale — the encoder canvas is fixed and frames are letter-boxed into it (the writer can't be resized).
- **Disk.** Below ~2 GB free → clean stop with save.
- **Energy.** Event-driven `SCStream`: the process doesn't wake between frames at all — WindowServer pushes a frame, and only when the screen changed (idle-suppression, WWDC22). A static screen = zero work across the whole pipeline. Capture is 420v (−62.5% memory traffic vs BGRA), zero-copy into the encoder, `.utility` QoS (efficiency cores), timers with tolerance, `beginActivity` against App Nap while still allowing system sleep. Static periods are automatically skipped in the final video.

---

## Architecture

```
RecordTimeLapseApp ─ MenuBarExtra(.window) + Settings        entry point (SwiftUI)
AppDelegate        ─ .accessory, crash recovery on launch
RecordingCoordinator (@MainActor)                            the brain: state machine, owns everything
├─ CaptureEngine        SCStream (event-driven frame delivery, idle-suppression)
├─ DisplayProvider      SCShareableContent → SCContentFilter/SCStreamConfiguration (420v, canvas)
├─ PermissionService    CGPreflight/CGRequest + SCShareableContent
├─ SegmentManager       segment rotation, manifest, Stitcher (passthrough)
│  └─ TimelapseEncoder  AVAssetWriter, zero-copy adaptor.append  ← the memory fix
│     └─ PixelBufferRenderer  CGImage → BGRA CVPixelBuffer, letterbox (fallback path only)
├─ PowerStateObserver   sleep/lock → pause/resume
├─ DiskSpaceMonitor     free-space threshold
└─ RecoveryManager      stitch segments after a crash
```

States: `idle → recording ⇄ paused → finalizing → idle`.

---

## References

The architecture is grounded in real open-source apps and Apple's docs:

- [wkaisertexas/ScreenTimeLapse (TimeLapze)](https://github.com/wkaisertexas/ScreenTimeLapse) — the main analog: streaming CMSampleBuffers into `AVAssetWriterInput`, constant memory.
- [wulkano/Aperture](https://github.com/wulkano/Aperture) — mature ScreenCaptureKit→disk wrapper (the engine behind Kap).
- [acj/TimeLapseBuilder-Swift](https://github.com/acj/TimeLapseBuilder-Swift) — the canonical writer/input/adaptor + buffer-pool pattern (it uses 32ARGB; this app uses 32BGRA, the encoder-native layout).
- Apple: [AVAssetWriterInputPixelBufferAdaptor](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor) · [movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval) · [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) · [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
