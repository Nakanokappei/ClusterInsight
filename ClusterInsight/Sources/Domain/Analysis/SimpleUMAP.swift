import Foundation
import Accelerate

// Cluster-aware 3D layout using PCA with centroid separation scaling.
// Based on the proven approach from LLM Topic Modeler:
//   1. Global PCA to project embeddings to 3D
//   2. Compute cluster centroids in 3D
//   3. Scale centroids outward for visual separation
//   4. Place members around their centroid using local PCA offsets
// This produces clear cluster separation without UMAP's convergence issues.
enum SimpleUMAP {

    // Reduce N high-dimensional vectors to 3D with cluster-aware layout.
    // labels: cluster assignment per point. nil = pure PCA without cluster enhancement.
    static func reduce(
        vectors: [[Float]],
        labels: [Int]? = nil,
        outputDimensions: Int = 3,
        nNeighbors: Int = 10,
        nEpochs: Int = 800
    ) -> [[Double]] {
        let n = vectors.count
        guard n > 1 else {
            return [[0, 0, 0]]
        }

        let dim = vectors[0].count

        // Step 1: Global PCA to get initial 3D coordinates.
        let globalCoords = performPCA(vectors: vectors, outputDims: outputDimensions)

        // Without cluster labels, return raw PCA coordinates.
        guard let labels else {
            return normalizeToUnitCube(globalCoords)
        }

        // Step 2: Compute cluster centroids in 3D PCA space.
        let uniqueLabels = Array(Set(labels).filter { $0 >= 0 }).sorted()
        guard !uniqueLabels.isEmpty else {
            return normalizeToUnitCube(globalCoords)
        }

        var centroids: [Int: [Double]] = [:]
        var memberIndices: [Int: [Int]] = [:]

        for label in uniqueLabels {
            let indices = (0..<n).filter { labels[$0] == label }
            memberIndices[label] = indices

            // Centroid = mean of member PCA coordinates.
            var centroid = [Double](repeating: 0, count: outputDimensions)
            for i in indices {
                for d in 0..<outputDimensions { centroid[d] += globalCoords[i][d] }
            }
            let count = Double(indices.count)
            for d in 0..<outputDimensions { centroid[d] /= count }
            centroids[label] = centroid
        }

        // Step 3: Scale centroids outward from the global center of mass.
        // Raw PCA centroids are often too close together for visual distinction.
        let centerOfMass = computeCenterOfMass(centroids: centroids)
        let scaledCentroids = scaleCentroidsForVisibility(
            centroids: centroids, center: centerOfMass, clusterCount: uniqueLabels.count
        )

        // Step 4: Place members around their scaled centroid.
        // Use local PCA offsets to preserve each cluster's internal structure.
        var result = [[Double]](repeating: [0, 0, 0], count: n)

        for label in uniqueLabels {
            guard let indices = memberIndices[label],
                  let centroid = scaledCentroids[label] else { continue }

            if indices.count == 1 {
                result[indices[0]] = centroid
                continue
            }

            // Compute local offsets from the cluster's PCA centroid.
            let memberGlobalCoords = indices.map { globalCoords[$0] }
            let localCentroid = centroids[label]!

            // Determine cluster radius based on relative size.
            let maxMembers = memberIndices.values.map(\.count).max() ?? 1
            let radius = 0.3 * sqrt(Double(indices.count) / Double(maxMembers))

            // Scale offsets to fit within the radius.
            var offsets = memberGlobalCoords.map { coord -> [Double] in
                (0..<outputDimensions).map { coord[$0] - localCentroid[$0] }
            }

            // Normalize offsets: find the 95th percentile distance for robust scaling.
            let distances = offsets.map { offset in
                sqrt(offset.reduce(0) { $0 + $1 * $1 })
            }.sorted()
            let p95Index = max(0, Int(Double(distances.count) * 0.95) - 1)
            let p95Distance = distances[p95Index]

            let scale = p95Distance > 1e-10 ? radius / p95Distance : 1.0

            for (localIdx, globalIdx) in indices.enumerated() {
                result[globalIdx] = (0..<outputDimensions).map { d in
                    centroid[d] + offsets[localIdx][d] * scale
                }
            }
        }

        // Place noise points (label == -1) at their raw PCA positions, slightly shrunk.
        for i in 0..<n where labels[i] < 0 {
            result[i] = globalCoords[i]
        }

        return normalizeToUnitCube(result)
    }

    // MARK: - PCA via Covariance + LAPACK Eigendecomposition

    // Perform PCA on the input vectors using the covariance matrix approach.
    // Returns N points in outputDims dimensions.
    private static func performPCA(vectors: [[Float]], outputDims: Int) -> [[Double]] {
        let n = vectors.count
        let dim = vectors[0].count

        // Compute the mean vector.
        var mean = [Float](repeating: 0, count: dim)
        for v in vectors {
            for d in 0..<dim { mean[d] += v[d] }
        }
        let nf = Float(n)
        for d in 0..<dim { mean[d] /= nf }

        // Center the data.
        let centered = vectors.map { v -> [Float] in
            (0..<dim).map { v[$0] - mean[$0] }
        }

        // For high-dimensional data (dim >> n), use the Gram matrix approach:
        // Compute N×N Gram matrix G = X * X^T, then eigen-decompose G.
        // This is O(n^2 * dim) instead of O(dim^2 * n) for covariance.
        var gram = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in i..<n {
                var dot: Float = 0
                vDSP_dotpr(centered[i], 1, centered[j], 1, &dot, vDSP_Length(dim))
                gram[i * n + j] = dot / nf
                gram[j * n + i] = dot / nf
            }
        }

        // Eigen-decompose the Gram matrix using LAPACK ssyev.
        var eigenvalues = [Float](repeating: 0, count: n)
        var matrix = gram // ssyev overwrites input with eigenvectors
        var jobz: Int8 = 86 // 'V' - compute eigenvectors
        var uplo: Int8 = 85 // 'U' - upper triangle
        var lda = Int32(n)
        var matrixN = Int32(n)
        var info: Int32 = 0

        // Query optimal workspace size.
        var workSize: Float = 0
        var lwork: Int32 = -1
        ssyev_(&jobz, &uplo, &matrixN, &matrix, &lda, &eigenvalues, &workSize, &lwork, &info)
        lwork = Int32(workSize)
        var work = [Float](repeating: 0, count: Int(lwork))
        ssyev_(&jobz, &uplo, &matrixN, &matrix, &lda, &eigenvalues, &work, &lwork, &info)

        guard info == 0 else {
            // Fallback: return centered coordinates projected onto first 3 dims.
            return centered.map { v in
                (0..<outputDims).map { Double(v[$0]) }
            }
        }

        // ssyev returns eigenvalues in ascending order. We want the largest ones.
        // Eigenvectors are stored column-major in 'matrix'.
        var result = [[Double]](repeating: [Double](repeating: 0, count: outputDims), count: n)
        for d in 0..<outputDims {
            let eigIdx = n - 1 - d // Largest eigenvalue first
            for i in 0..<n {
                result[i][d] = Double(matrix[eigIdx * n + i])
            }
        }

        return result
    }

    // MARK: - Centroid Scaling

    private static func computeCenterOfMass(centroids: [Int: [Double]]) -> [Double] {
        let dims = centroids.values.first?.count ?? 3
        var com = [Double](repeating: 0, count: dims)
        for c in centroids.values {
            for d in 0..<dims { com[d] += c[d] }
        }
        let count = Double(centroids.count)
        for d in 0..<dims { com[d] /= count }
        return com
    }

    // Scale centroids outward from center of mass so clusters are visually separated.
    // Uses nearest-neighbor distance among centroids to determine how much to expand.
    private static func scaleCentroidsForVisibility(
        centroids: [Int: [Double]], center: [Double], clusterCount: Int
    ) -> [Int: [Double]] {
        let dims = center.count

        // Compute pairwise distances between centroids.
        let keys = Array(centroids.keys.sorted())
        var minNNDistance = Double.infinity
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let ci = centroids[keys[i]]!
                let cj = centroids[keys[j]]!
                let dist = sqrt(zip(ci, cj).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
                minNNDistance = min(minNNDistance, dist)
            }
        }

        // Gentle expansion: just enough to see cluster boundaries without flying apart.
        // Scale factor is capped at 1.5x to preserve the original PCA layout proportions.
        let targetMinNN = max(0.2, 0.5 / cbrt(Double(clusterCount)))
        let rawScale = minNNDistance > 1e-10 ? targetMinNN / minNNDistance : 1.0
        let scaleFactor = min(max(1.0, rawScale), 1.8)

        // Scale each centroid outward from the center of mass.
        var scaled: [Int: [Double]] = [:]
        for (label, centroid) in centroids {
            scaled[label] = (0..<dims).map { d in
                center[d] + (centroid[d] - center[d]) * scaleFactor
            }
        }
        return scaled
    }

    // MARK: - Normalization

    // Normalize all coordinates to fit within [-1, 1] for SceneKit rendering.
    private static func normalizeToUnitCube(_ coords: [[Double]]) -> [[Double]] {
        guard !coords.isEmpty else { return coords }
        let dims = coords[0].count

        var mins = [Double](repeating: Double.infinity, count: dims)
        var maxs = [Double](repeating: -Double.infinity, count: dims)
        for c in coords {
            for d in 0..<dims {
                mins[d] = min(mins[d], c[d])
                maxs[d] = max(maxs[d], c[d])
            }
        }

        let ranges = (0..<dims).map { maxs[$0] - mins[$0] }
        let maxRange = ranges.max() ?? 1.0
        let scale = maxRange > 1e-10 ? 2.0 / maxRange : 1.0

        let centers = (0..<dims).map { (maxs[$0] + mins[$0]) / 2.0 }

        return coords.map { c in
            (0..<dims).map { d in (c[d] - centers[d]) * scale }
        }
    }
}
