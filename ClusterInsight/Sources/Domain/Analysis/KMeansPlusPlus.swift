import Foundation
import Accelerate

// k-means++ clustering with cosine distance.
// Optimized for the 500-record demo dataset using Accelerate for vector operations.
enum KMeansPlusPlus {

    // Cluster the given vectors into k groups using k-means++ initialization.
    // Returns an array of cluster labels (0 to k-1) corresponding to each input vector.
    static func cluster(vectors: [[Float]], k: Int, maxIterations: Int = 100) -> [Int] {
        guard !vectors.isEmpty, k > 0 else { return [] }
        let n = vectors.count
        let dim = vectors[0].count

        // Normalize all vectors to unit length for cosine distance as 1 - dot product.
        let normalized = vectors.map { normalize($0) }

        // Initialize centroids using the k-means++ seeding strategy.
        var centroids = initializeCentroids(vectors: normalized, k: k)
        var labels = [Int](repeating: 0, count: n)

        for _ in 0..<maxIterations {
            // Assignment step: assign each point to the nearest centroid.
            var newLabels = [Int](repeating: 0, count: n)
            for i in 0..<n {
                var bestLabel = 0
                var bestSimilarity: Float = -Float.infinity
                for j in 0..<centroids.count {
                    let similarity = dotProduct(normalized[i], centroids[j])
                    if similarity > bestSimilarity {
                        bestSimilarity = similarity
                        bestLabel = j
                    }
                }
                newLabels[i] = bestLabel
            }

            // Check for convergence: stop when no assignments change.
            if newLabels == labels { break }
            labels = newLabels

            // Update step: recompute each centroid as the mean of its assigned vectors.
            var newCentroids = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)

            for i in 0..<n {
                let label = labels[i]
                counts[label] += 1
                for d in 0..<dim {
                    newCentroids[label][d] += normalized[i][d]
                }
            }

            // Normalize updated centroids. Keep the old centroid if a cluster is empty.
            for j in 0..<k {
                if counts[j] > 0 {
                    let count = Float(counts[j])
                    for d in 0..<dim {
                        newCentroids[j][d] /= count
                    }
                    newCentroids[j] = normalize(newCentroids[j])
                } else {
                    newCentroids[j] = centroids[j]
                }
            }
            centroids = newCentroids
        }

        return labels
    }

    // Select initial centroids using the k-means++ probabilistic seeding.
    // The first centroid is random; subsequent centroids are chosen proportional
    // to squared cosine distance from the nearest existing centroid.
    private static func initializeCentroids(vectors: [[Float]], k: Int) -> [[Float]] {
        let n = vectors.count
        var centroids: [[Float]] = []

        // Pick the first centroid uniformly at random.
        let firstIndex = Int.random(in: 0..<n)
        centroids.append(vectors[firstIndex])

        // Pick remaining centroids with probability proportional to distance squared.
        for _ in 1..<k {
            var distances = [Float](repeating: Float.infinity, count: n)
            for i in 0..<n {
                for centroid in centroids {
                    let dist = 1.0 - dotProduct(vectors[i], centroid)
                    distances[i] = min(distances[i], dist * dist)
                }
            }

            // Weighted random selection based on distance squared.
            let totalWeight = distances.reduce(0, +)
            guard totalWeight > 0 else { break }
            var threshold = Float.random(in: 0..<totalWeight)
            var selectedIndex = 0
            for i in 0..<n {
                threshold -= distances[i]
                if threshold <= 0 {
                    selectedIndex = i
                    break
                }
            }
            centroids.append(vectors[selectedIndex])
        }

        return centroids
    }

    // Compute the dot product of two Float arrays using Accelerate for speed.
    private static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    // Normalize a vector to unit length for cosine similarity as dot product.
    private static func normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
