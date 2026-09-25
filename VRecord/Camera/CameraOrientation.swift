import AVFoundation
import ImageIO
import UIKit

extension UIInterfaceOrientation {
    var captureVideoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .landscapeLeft:
            .landscapeLeft
        case .landscapeRight:
            .landscapeRight
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        default:
            nil
        }
    }
}


extension UIInterfaceOrientation {
    /// Orientation used by Vision to interpret an unmirrored rear-camera pixel buffer.
    var visionImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .landscapeLeft:
            .left
        case .landscapeRight:
            .right
        case .portrait:
            .up
        case .portraitUpsideDown:
            .down
        default:
            .right
        }
    }
}
