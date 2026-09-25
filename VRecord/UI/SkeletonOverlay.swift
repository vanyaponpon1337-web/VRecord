import SwiftUI

struct SkeletonOverlay: View {
    let skeleton: HandSkeleton?
    let sourceAspectRatio: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let skeleton else {
                return
            }

            let color: Color = skeleton.isPinching ? .red : .white

            for (startJoint, endJoint) in HandSkeleton.connections {
                guard
                    let start = skeleton.point(startJoint),
                    let end = skeleton.point(endJoint)
                else {
                    continue
                }

                let startPoint = HandCoordinateConverter.viewPoint(
                    for: start,
                    sourceAspectRatio: sourceAspectRatio,
                    in: size
                )
                let endPoint = HandCoordinateConverter.viewPoint(
                    for: end,
                    sourceAspectRatio: sourceAspectRatio,
                    in: size
                )
                var path = Path()
                path.move(to: startPoint)
                path.addLine(to: endPoint)
                context.stroke(path, with: .color(color), lineWidth: 2.5)
            }

            for point in skeleton.points.values {
                let viewPoint = HandCoordinateConverter.viewPoint(
                    for: point,
                    sourceAspectRatio: sourceAspectRatio,
                    in: size
                )
                let jointRect = CGRect(
                    x: viewPoint.x - 3.25,
                    y: viewPoint.y - 3.25,
                    width: 6.5,
                    height: 6.5
                )
                context.fill(Path(ellipseIn: jointRect), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
