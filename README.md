# VRecord

Native iPhone iOS application for a Cardboard-style stereoscopic camera experience. The rear wide-angle camera is shown simultaneously in two equal landscape viewports. Apple Vision tracks one hand and renders a skeleton; pinch controls photo and video capture.

## Requirements

- macOS with a supported Xcode version
- iPhone with a rear wide-angle camera
- iOS 17.0 or newer
- A physical iPhone is required for camera/Vision runtime testing

## Features

- Landscape-only UI (left/right)
- Rear wide-angle camera
- 60 FPS preference with automatic device-format fallback
- Low-latency `AVCaptureVideoDataOutput` with late-frame dropping
- Apple Vision hand-pose detection with one-hand selection/tracking
- White hand skeleton; red while pinch is active
- Cardboard split: identical camera preview in two symmetric halves
- Pinch hysteresis, smoothing and debounce
- Short pinch (up to 1.0 s) -> photo after release
- Long pinch (>1.0 s) -> video; recording stops on release
- Photo flash overlay (100 ms)
- Recording indicators in both viewports
- Photos/Video saved to the system Photos library
- Camera and Photos permissions handling
- Unit tests for capture state, pinch detection and coordinate conversion
- GitHub Actions unsigned build/test workflow

## Project structure

- `VRecord/App` - app entry point and orientation handling
- `VRecord/Camera` - AVFoundation session, camera formats, photo/video output
- `VRecord/Vision` - Vision hand tracking and coordinate conversion
- `VRecord/Gesture` - pinch detector and capture state machine
- `VRecord/UI` - SwiftUI experience and Cardboard split view
- `VRecord/Models` - normalized hand landmarks
- `VRecord/Services` - Photos library persistence
- `VRecordTests` - unit tests

## Open and run

```bash
git clone <YOUR_REPOSITORY_URL>
cd VRecord
open VRecord.xcodeproj
```

Select an iPhone target, set your Apple development team if required, then Run. Camera/Vision functionality cannot be meaningfully tested in the iOS Simulator.

The default bundle identifier is `com.example.VRecord`. Change it under the app target's **Signing & Capabilities** / **General** settings before App Store distribution.

## Permissions

The app declares:

- `NSCameraUsageDescription`
- `NSPhotoLibraryAddUsageDescription`

Only add additional permissions if the implementation is changed to require them.

## GitHub Actions

`.github/workflows/build.yml` runs on GitHub's macOS runner for pushes, pull requests and manual dispatch. It builds and tests without signing credentials. The workflow uses the repository's Xcode project and scheme and disables code signing for the CI build.

For a signed IPA later, add an Apple Developer signing certificate, provisioning profile and App Store Connect API key as GitHub secrets or use GitHub Actions environments. Do not commit certificates, private keys or provisioning profiles.

## Troubleshooting

### Camera unavailable

Check that the app is running on a physical iPhone, camera access is granted, and no other process is occupying the camera.

### Vision does not detect a hand

Use good lighting, keep one hand clearly visible, and avoid severe occlusion. Vision analysis is intentionally throttled so the camera preview stays responsive.

### 60 FPS is unavailable

VRecord selects the closest supported rear-camera format/rate and falls back safely. The actual configured rate is exposed by `CameraManager.configuredFrameRate` for diagnostics.

### Photos access denied

Open iOS Settings and grant Photos access. VRecord requests add-only Photos permission because it only creates new assets.

### GitHub Actions signing errors

The CI workflow is deliberately unsigned. For distribution, configure a signing identity, provisioning profile and App Store Connect authentication separately; never put those credentials in source control.
