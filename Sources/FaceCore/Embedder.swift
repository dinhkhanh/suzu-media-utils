import CoreML
import Foundation

/// Runs a converted face-embedding model. Input: RGB 0-255 [N,3,112,112]; output: L2-normalized [N,D].
public final class Embedder {
    public let name: String
    let model: MLModel

    public init(name: String, compiledModel: URL, computeUnits: MLComputeUnits = .all) throws {
        self.name = name
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledModel, configuration: cfg)
    }

    /// Batch sizes the model was converted with (enumerated shapes; required for the Neural Engine).
    static let batchSizes = [1, 16]

    /// `crops` are 112x112 RGBA8 buffers. Returns one embedding per crop.
    public func embed(_ crops: [[UInt8]]) throws -> [[Float]] {
        let batchSize = Self.batchSizes.last!
        var out: [[Float]] = []
        out.reserveCapacity(crops.count)
        var start = 0
        while start < crops.count {
            let n = min(batchSize, crops.count - start)
            // A padded batch of 16 costs as much as 16 faces; below half full, single calls are cheaper.
            if n >= batchSize / 2 {
                out += try embedBatch(Array(crops[start..<start + n]))
            } else {
                for c in crops[start..<start + n] { out += try embedBatch([c]) }
            }
            start += n
        }
        return out
    }

    func embedBatch(_ crops: [[UInt8]]) throws -> [[Float]] {
        let plane = FaceAligner.side * FaceAligner.side
        // Short batches are zero-padded up to the next supported size.
        let padded = Self.batchSizes.first { $0 >= crops.count }!
        let input = try MLMultiArray(shape: [padded, 3, FaceAligner.side, FaceAligner.side] as [NSNumber],
                                     dataType: .float32)
        let p = input.dataPointer.bindMemory(to: Float.self, capacity: padded * 3 * plane)
        p.update(repeating: 0, count: padded * 3 * plane)
        for (i, c) in crops.enumerated() {
            let base = i * 3 * plane
            for k in 0..<plane {
                p[base + k] = Float(c[k * 4])
                p[base + plane + k] = Float(c[k * 4 + 1])
                p[base + 2 * plane + k] = Float(c[k * 4 + 2])
            }
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let e = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        let dim = e.shape[1].intValue
        return (0..<crops.count).map { i in
            (0..<dim).map { j in e[[i, j] as [NSNumber]].floatValue }
        }
    }
}
