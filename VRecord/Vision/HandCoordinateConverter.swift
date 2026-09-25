import CoreGraphics

enum HandCoordinateConverter {
    static func viewPoint(
        for point: NormalizedPoint,
        sourceAspectRatio: CGFloat,
        in viewportSize: CGSize
    ) -> CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }

        let sourceSize = CGSize(
            width: max(sourceAspectRatio, 0.001),
            height: 1
        )
        let scale = max(
            viewportSize.width / sourceSize.width,
            viewportSize.height / sourceSize.height
        )
        let renderedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let origin = CGPoint(
            x: (viewportSize.width - renderedSize.width) / 2,
            y: (viewportSize.height - renderedSize.height) / 2
        )

        return CGPoint(
            x: origin.x + point.x * renderedSize.width,
            y: origin.y + (1 - point.y) * renderedSize.height
        )
    }
}
