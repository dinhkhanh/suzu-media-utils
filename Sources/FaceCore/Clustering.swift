import Accelerate
import Foundation

public enum Clustering {
    /// Pairwise cosine similarity of L2-normalized rows, as a flat n*n matrix.
    public static func similarityMatrix(_ emb: [[Float]]) -> [Float] {
        let n = emb.count, d = emb.first?.count ?? 0
        let x = emb.flatMap { $0 }
        var s = [Float](repeating: 0, count: n * n)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(d),
                    1, x, Int32(d), x, Int32(d), 0, &s, Int32(n))
        return s
    }

    /// Average-linkage agglomerative clustering: merges clusters while their mean pairwise similarity is at
    /// least `threshold`. Average linkage resists the chaining that single linkage shows on blurry faces.
    /// Returns a cluster label per item; labels are ordered by cluster size, largest first.
    public static func averageLinkage(similarity sim: [Float], count n: Int, threshold: Float) -> [Int] {
        var s = sim
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var members = (0..<n).map { [$0] }
        var best = [Int](repeating: -1, count: n)

        func refresh(_ i: Int) {
            var bj = -1, bv = -Float.infinity
            for j in 0..<n where j != i && active[j] && s[i * n + j] > bv { bv = s[i * n + j]; bj = j }
            best[i] = bj
        }
        for i in 0..<n { refresh(i) }

        while true {
            var bi = -1, bv = -Float.infinity
            for i in 0..<n where active[i] && best[i] >= 0 && s[i * n + best[i]] > bv { bv = s[i * n + best[i]]; bi = i }
            if bi < 0 || bv < threshold { break }
            let i = bi, j = best[bi]
            let si = Float(size[i]), sj = Float(size[j])
            for k in 0..<n where active[k] && k != i && k != j {
                let v = (si * s[i * n + k] + sj * s[j * n + k]) / (si + sj)
                s[i * n + k] = v
                s[k * n + i] = v
            }
            size[i] += size[j]
            members[i] += members[j]
            active[j] = false
            members[j] = []
            // The merged similarity never exceeds the larger of the two old ones, so only rows that pointed at
            // i or j can lose their best partner.
            for k in 0..<n where active[k] && (k == i || best[k] == i || best[k] == j) { refresh(k) }
        }

        var labels = [Int](repeating: -1, count: n)
        let clusters = members.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for (c, m) in clusters.enumerated() { for i in m { labels[i] = c } }
        return labels
    }
}
