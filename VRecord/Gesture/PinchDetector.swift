import Foundation

struct PinchDetector {
    struct Configuration: Equatable {
        let startThreshold: CGFloat
        let endThreshold: CGFloat
        let smoothingFactor: CGFloat
        let debounceFrameCount: Int
        let minimumReferenceScale: CGFloat

        init(
            startThreshold: CGFloat = 0.23,
            endThreshold: CGFloat = 0.31,
            smoothingFactor: CGFloat = 0.35,
            debounceFrameCount: Int = 2,
            minimumReferenceScale: CGFloat = 0.025
        ) {
            precondition(startThreshold < endThreshold, "Pinch hysteresis requires a wider end threshold.")
            precondition((0 ... 1).contains(smoothingFactor), "Smoothing factor must be normalized.")
            precondition(debounceFrameCount > 0, "At least one frame is required for debounce.")

            self.startThreshold = startThreshold
            self.endThreshold = endThreshold
            self.smoothingFactor = smoothingFactor
            self.debounceFrameCount = debounceFrameCount
            self.minimumReferenceScale = minimumReferenceScale
        }
    }

    private(set) var isPinching = false
    private(set) var smoothedDistance: CGFloat?
    private var startCandidateFrames = 0
    private var endCandidateFrames = 0
    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func update(
        with skeleton: HandSkeleton,
        sourceAspectRatio: CGFloat = 1
    ) -> Bool {
        guard
            let thumbTip = skeleton.point(.thumbTip),
            let indexTip = skeleton.point(.indexTip),
            let referenceScale = handReferenceScale(
                for: skeleton,
                sourceAspectRatio: sourceAspectRatio
            ),
            referenceScale >= configuration.minimumReferenceScale
        else {
            return isPinching
        }

        return update(
            thumbTip: thumbTip,
            indexTip: indexTip,
            referenceScale: referenceScale,
            sourceAspectRatio: sourceAspectRatio
        )
    }

    mutating func update(
        thumbTip: NormalizedPoint,
        indexTip: NormalizedPoint,
        referenceScale: CGFloat,
        sourceAspectRatio: CGFloat = 1
    ) -> Bool {
        guard referenceScale >= configuration.minimumReferenceScale else {
            return isPinching
        }

        let normalizedDistance = thumbTip.distance(
            to: indexTip,
            sourceAspectRatio: sourceAspectRatio
        ) / referenceScale
        let filteredDistance: CGFloat

        if let smoothedDistance {
            filteredDistance = smoothedDistance
                + configuration.smoothingFactor * (normalizedDistance - smoothedDistance)
        } else {
            filteredDistance = normalizedDistance
        }

        smoothedDistance = filteredDistance

        if isPinching {
            if filteredDistance > configuration.endThreshold {
                endCandidateFrames += 1
                if endCandidateFrames >= configuration.debounceFrameCount {
                    isPinching = false
                    startCandidateFrames = 0
                    endCandidateFrames = 0
                }
            } else {
                endCandidateFrames = 0
            }
        } else {
            if filteredDistance < configuration.startThreshold {
                startCandidateFrames += 1
                if startCandidateFrames >= configuration.debounceFrameCount {
                    isPinching = true
                    startCandidateFrames = 0
                    endCandidateFrames = 0
                }
            } else {
                startCandidateFrames = 0
            }
        }

        return isPinching
    }

    mutating func reset() {
        isPinching = false
        smoothedDistance = nil
        startCandidateFrames = 0
        endCandidateFrames = 0
    }

    private func handReferenceScale(
        for skeleton: HandSkeleton,
        sourceAspectRatio: CGFloat
    ) -> CGFloat? {
        guard let wrist = skeleton.point(.wrist) else {
            return nil
        }

        let palmAnchors: [HandJoint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let distances = palmAnchors.compactMap {
            skeleton.point($0)?.distance(to: wrist, sourceAspectRatio: sourceAspectRatio)
        }

        guard !distances.isEmpty else {
            return nil
        }

        return distances.reduce(0, +) / CGFloat(distances.count)
    }
}
