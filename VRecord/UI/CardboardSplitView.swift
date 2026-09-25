import AVFoundation
import SwiftUI
import UIKit

struct CardboardSplitView: View {
    @ObservedObject var cameraManager: CameraManager
    let skeleton: HandSkeleton?
    let showPhotoFlash: Bool
    let interfaceOrientation: UIInterfaceOrientation

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    StereoViewport(
                        session: cameraManager.session,
                        skeleton: skeleton,
                        sourceAspectRatio: cameraManager.videoAspectRatio,
                        interfaceOrientation: interfaceOrientation,
                        isRecording: cameraManager.isRecording,
                        safeLeadingInset: geometry.safeAreaInsets.leading
                    )

                    StereoViewport(
                        session: cameraManager.session,
                        skeleton: skeleton,
                        sourceAspectRatio: cameraManager.videoAspectRatio,
                        interfaceOrientation: interfaceOrientation,
                        isRecording: cameraManager.isRecording,
                        safeLeadingInset: 0
                    )
                }

                if showPhotoFlash {
                    Color.white
                        .opacity(0.96)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

private struct StereoViewport: View {
    let session: AVCaptureSession
    let skeleton: HandSkeleton?
    let sourceAspectRatio: CGFloat
    let interfaceOrientation: UIInterfaceOrientation
    let isRecording: Bool
    let safeLeadingInset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(
                session: session,
                interfaceOrientation: interfaceOrientation
            )

            SkeletonOverlay(
                skeleton: skeleton,
                sourceAspectRatio: sourceAspectRatio
            )

            if isRecording {
                RecordingIndicator()
                    .padding(.leading, max(12, safeLeadingInset + 8))
                    .padding(.top, 12)
            }
        }
        .clipped()
    }
}

private struct RecordingIndicator: View {
    var body: some View {
        Circle()
            .fill(Color.red.opacity(0.72))
            .frame(width: 16, height: 16)
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityLabel("Recording")
    }
}
