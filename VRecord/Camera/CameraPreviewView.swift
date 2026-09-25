import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let interfaceOrientation: UIInterfaceOrientation

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.configure(session: session, interfaceOrientation: interfaceOrientation)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.configure(session: session, interfaceOrientation: interfaceOrientation)
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("CameraPreviewUIView requires AVCaptureVideoPreviewLayer.")
        }
        return layer
    }

    func configure(
        session: AVCaptureSession,
        interfaceOrientation: UIInterfaceOrientation
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        if
            let orientation = interfaceOrientation.captureVideoOrientation,
            let connection = previewLayer.connection
        {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }

            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        CATransaction.commit()
    }
}
