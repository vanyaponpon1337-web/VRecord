# VRecord

Native Swift iPhone camera for iOS 18.5+, bundle `com.vrecord.app`. The app uses the physical rear ultra-wide camera, Apple Vision two-hand pose tracking, GPU-baked skeletons, and an immersive monoscopic SBS Metal preview. There are no on-screen controls or text.

- Release a pinch before one second to save one normal single-view photo with skeleton pixels.
- Hold either hand's pinch for at least one second to begin H.264 MP4 recording with AAC microphone audio.
- Release the initiating pinch, then make a fresh pinch with either hand to stop. Held/simultaneous start gestures cannot stop or restart recording.
- Pinching hands turn red independently. Two small red preview circles indicate recording.

Camera/microphone prompts use iOS APIs. Photos requests add-only authorization when saving. Denied camera access leaves the black immersive surface; restore permission in iOS Settings. Denied microphone access permits video without an audio track and logs that condition. If authorized audio unexpectedly produces no samples, recording reports failure rather than reporting a successful silent recording. Errors use the system log, preserving the requested visual restrictions.

## Build and download

GitHub Actions runs deterministic Swift tests, builds a physical ARM64 iOS app with code signing disabled, verifies the Mach-O executable is unsigned and unencrypted and that assets/Metal/privacy keys exist, and packages `Payload/VRecord.app` into `VRecord-Unsigned.ipa`. Download the `VRecord-Unsigned` artifact from a successful run and extract the IPA. The original build contains no FairPlay encryption. Independent signing is required before installation; no signing certificate is used to build this artifact.

The checked-in Xcode project and shared scheme have no external dependencies. `python3 scripts/generate_project.py` regenerates them and native icon assets. `swift test` on macOS runs the gesture tests. Xcode 16.4 with iOS 18.5 SDK or a newer compatible Xcode builds the app. Windows does not need Xcode.

## Pipeline and runtime limits

Capture selects a genuine ultra-wide format advertising 60 FPS, preferring 1920×1080, and sets both frame durations to 1/60. AVFoundation rotates unmirrored BGRA buffers into upright landscape coordinates. Vision runs on a separate queue with one in-flight and one replaceable pending frame, uses at most two hands, and expires stale overlays. Metal composites single-view skeletons into reusable bounded pixel buffers; the identical result feeds both SBS eyes, photos, and AVAssetWriter. Crop is applied only to the SBS preview, preserving normal image proportions in exports. Encoder and GPU work are bounded; overload drops frames instead of building latency.

Backgrounding, capture/audio interruption, rotation during recording, and memory pressure finalize recording safely. The camera resumes when the application is active. The app prevents display sleep while active.

CI cannot establish physical iPhone 16 camera availability, sustained real capture/presentation/encoding rates, thermal behavior, hand-tracking accuracy/identity through occlusion, pinch thresholds at all distances, Photos permissions on device, microphone sound quality, VR comfort, or independent-signing compatibility. Verify those on an iPhone 16 running iOS 18.5. The selected capture format targets real 60 FPS; sustained measured 60 FPS is not claimed without device testing. Tracking loss cancels a pending short gesture to avoid accidental photos; a lost/reacquired held pinch must release before a new command.
