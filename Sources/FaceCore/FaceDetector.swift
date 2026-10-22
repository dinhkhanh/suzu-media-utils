import CoreGraphics
import Foundation
import Vision

public struct Point2: Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ p: CGPoint) { x = p.x; y = p.y }
    public var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// A face in detection-image pixel coordinates, top-left origin.
public struct DetectedFace: Codable, Sendable {
    public var x, y, w, h: Double
    /// Left eye, right eye, nose, left mouth corner, right mouth corner (image left/right).
    public var points: [Point2]?
    public var quality: Float?
    public var yaw, roll, pitch: Float?

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public enum FaceDetector {
    public static func detect(_ image: CGImage) throws -> [DetectedFace] {
        let size = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let landmarks = VNDetectFaceLandmarksRequest()
        try handler.perform([landmarks])
        let observations = landmarks.results ?? []
        if observations.isEmpty { return [] }

        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = observations
        try handler.perform([quality])
        var qualityByID: [UUID: Float] = [:]
        for q in quality.results ?? [] { qualityByID[q.uuid] = q.faceCaptureQuality }

        return observations.map { o in
            let b = VNImageRectForNormalizedRect(o.boundingBox, image.width, image.height)
            return DetectedFace(
                x: b.minX, y: size.height - b.maxY, w: b.width, h: b.height,
                points: fivePoints(o, size: size)?.map(Point2.init),
                quality: qualityByID[o.uuid],
                yaw: o.yaw?.floatValue, roll: o.roll?.floatValue, pitch: o.pitch?.floatValue)
        }
    }

    /// Derives the 5 ArcFace alignment points from Vision's 76-point landmarks.
    static func fivePoints(_ o: VNFaceObservation, size: CGSize) -> [CGPoint]? {
        guard let l = o.landmarks, let nose = l.nose, let lips = l.outerLips else { return nil }
        func pts(_ r: VNFaceLandmarkRegion2D) -> [CGPoint] {
            r.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        func mean(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / Double(p.count), y: p.map(\.y).reduce(0, +) / Double(p.count))
        }
        func eye(_ pupil: VNFaceLandmarkRegion2D?, _ contour: VNFaceLandmarkRegion2D?) -> CGPoint? {
            if let p = pupil, p.pointCount > 0 { return mean(pts(p)) }
            if let c = contour, c.pointCount > 0 { return mean(pts(c)) }
            return nil
        }
        guard let e1 = eye(l.leftPupil, l.leftEye), let e2 = eye(l.rightPupil, l.rightEye) else { return nil }
        let eyes = [e1, e2].sorted { $0.x < $1.x }
        let mouth = pts(lips).sorted { $0.x < $1.x }
        guard let ml = mouth.first, let mr = mouth.last else { return nil }
        return [eyes[0], eyes[1], mean(pts(nose)), ml, mr]
    }
}
