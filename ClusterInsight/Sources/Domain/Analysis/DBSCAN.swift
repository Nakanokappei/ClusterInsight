import Foundation
import Accelerate

// DBSCAN density-based clustering with cosine distance.
// Points in sparse regions are labeled as noise (-1).
enum DBSCAN {

    // Cluster the given vectors using the DBSCAN algorithm.
    // Returns an array of cluster labels: 0+ for clusters, -1 for noise points.
    static func cluster(vectors: [[Float]], epsilon: Double, minSamples: Int) -> [Int] {
        let n = vectors.count
        guard n > 0 else { return [] }

        // Precompute the full pairwise cosine distance matrix for efficient neighbor queries.
        let distanceMatrix = computeDistanceMatrix(vectors: vectors)

        var labels = [Int](repeating: -2, count: n) // -2 = unvisited
        var currentCluster = 0

        for i in 0..<n {
            // Skip points that have already been assigned a label.
            guard labels[i] == -2 else { continue }

            // Find all neighbors within epsilon distance of point i.
            let neighbors = regionQuery(distanceMatrix: distanceMatrix, pointIndex: i, epsilon: Float(epsilon), n: n)

            if neighbors.count < minSamples {
                // Not enough neighbors: mark as noise. May be reclaimed later.
                labels[i] = -1
            } else {
                // Start a new cluster and expand it from this core point.
                expandCluster(
                    distanceMatrix: distanceMatrix,
                    labels: &labels,
                    pointIndex: i,
                    neighbors: neighbors,
                    clusterLabel: currentCluster,
                    epsilon: Float(epsilon),
                    minSamples: minSamples,
                    n: n
                )
                currentCluster += 1
            }
        }

        return labels
    }

    // Expand a cluster from a core point by recursively adding density-reachable points.
    private static func expandCluster(
        distanceMatrix: [Float],
        labels: inout [Int],
        pointIndex: Int,
        neighbors: [Int],
        clusterLabel: Int,
        epsilon: Float,
        minSamples: Int,
        n: Int
    ) {
        labels[pointIndex] = clusterLabel
        var queue = neighbors
        // Track points already enqueued to prevent exponential queue growth.
        var enqueued = Set(neighbors)
        enqueued.insert(pointIndex)

        var queueIndex = 0
        while queueIndex < queue.count {
            let neighbor = queue[queueIndex]
            queueIndex += 1

            // Reclaim noise points into this cluster.
            if labels[neighbor] == -1 {
                labels[neighbor] = clusterLabel
            }

            // Skip points that are already in a cluster.
            guard labels[neighbor] == -2 else { continue }

            labels[neighbor] = clusterLabel

            // Check if this neighbor is also a core point, extending the cluster boundary.
            let neighborNeighbors = regionQuery(
                distanceMatrix: distanceMatrix,
                pointIndex: neighbor,
                epsilon: epsilon,
                n: n
            )
            if neighborNeighbors.count >= minSamples {
                for nn in neighborNeighbors where !enqueued.contains(nn) {
                    queue.append(nn)
                    enqueued.insert(nn)
                }
            }
        }
    }

    // Find all points within epsilon cosine distance of the given point.
    private static func regionQuery(distanceMatrix: [Float], pointIndex: Int, epsilon: Float, n: Int) -> [Int] {
        var neighbors: [Int] = []
        let offset = pointIndex * n
        for j in 0..<n {
            if distanceMatrix[offset + j] <= epsilon {
                neighbors.append(j)
            }
        }
        return neighbors
    }

    // Compute the full N×N pairwise cosine distance matrix.
    // Uses normalized vectors so cosine distance = 1 - dot_product.
    private static func computeDistanceMatrix(vectors: [[Float]]) -> [Float] {
        let n = vectors.count
        let dim = vectors[0].count

        // Normalize all vectors to unit length.
        let normalized = vectors.map { vector -> [Float] in
            var norm: Float = 0
            vDSP_svesq(vector, 1, &norm, vDSP_Length(dim))
            norm = sqrt(norm)
            guard norm > 0 else { return vector }
            var result = [Float](repeating: 0, count: dim)
            var divisor = norm
            vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(dim))
            return result
        }

        // Compute pairwise dot products and convert to distances.
        var distances = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in i..<n {
                if i == j {
                    distances[i * n + j] = 0
                } else {
                    var dot: Float = 0
                    vDSP_dotpr(normalized[i], 1, normalized[j], 1, &dot, vDSP_Length(dim))
                    let dist = 1.0 - dot
                    distances[i * n + j] = dist
                    distances[j * n + i] = dist
                }
            }
        }

        return distances
    }
}
