import Foundation
import GRDB

// Orchestrates the analysis pipeline by coordinating use cases and updating AppState.
// Each public method corresponds to a user action and manages the state transitions.
@MainActor
@Observable
final class MainViewModel {
    let appState: AppState
    let database: DatabaseManager

    private var openAIClient: OpenAIClient?

    init(appState: AppState, database: DatabaseManager) {
        self.appState = appState
        self.database = database
        // Initialize the API client if a key is already stored.
        if appState.hasAPIKey {
            openAIClient = OpenAIClient(apiKey: appState.apiKey)
        }
    }

    // MARK: - API Key Management

    // Update the API key and reinitialize the OpenAI client, then validate.
    func setAPIKey(_ key: String) {
        appState.apiKey = key
        openAIClient = OpenAIClient(apiKey: key)
        if case .apiKeyMissing = appState.phase {
            appState.phase = .columnSelected
        }
        Task { await validateAPIKey() }
    }

    // Validate the stored API key by making a lightweight embedding request.
    // Updates appState.apiKeyStatus so the UI can warn the user if the key is bad.
    func validateAPIKey() async {
        guard appState.hasAPIKey else {
            appState.apiKeyStatus = .unknown
            return
        }
        if openAIClient == nil {
            openAIClient = OpenAIClient(apiKey: appState.apiKey)
        }
        appState.apiKeyStatus = .validating
        let error = await openAIClient?.validateKey()
        if let error {
            appState.apiKeyStatus = .invalid(error)
        } else {
            appState.apiKeyStatus = .valid
        }
    }

    // MARK: - CSV Import (S0 → S1 → S2)

    // Import a CSV file, parse its contents, and store records in the database.
    // Handles sandbox security-scoped URL access for NSOpenPanel results.
    func importCSV(url: URL) async {
        appState.isProcessing = true
        appState.statusMessage = "CSV ファイルを読み込んでいます..."

        // Begin accessing the security-scoped resource for sandboxed file reads.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let parsedRows = try CSVParser.parse(url: url)
            let fileName = url.lastPathComponent
            let filePath = url.path
            let db = database.writer

            // Store the dataset and its records in the database.
            // Use lastInsertedRowID as a reliable way to get the auto-increment id.
            let dataset = try await db.write { dbConnection -> Dataset in
                var ds = Dataset(
                    name: fileName,
                    filePath: filePath,
                    recordCount: parsedRows.count,
                    importedAt: Date()
                )
                try ds.insert(dbConnection)
                let datasetId = dbConnection.lastInsertedRowID

                for row in parsedRows {
                    var record = TranscriptRecord(
                        datasetId: datasetId,
                        originalNo: row.no,
                        datetime: row.datetime.isEmpty ? nil : row.datetime,
                        duration: row.duration.isEmpty ? nil : row.duration,
                        status: row.status.isEmpty ? nil : row.status,
                        textContent: row.text,
                        textLength: row.text.count
                    )
                    try record.insert(dbConnection)
                }
                ds.id = datasetId
                return ds
            }

            // Load all records into memory for display.
            guard let datasetId = dataset.id else {
                throw NSError(domain: "ClusterInsight", code: 1, userInfo: [NSLocalizedDescriptionKey: "データセットIDの取得に失敗"])
            }
            let records = try await db.read { dbConnection in
                try TranscriptRecord
                    .filter(Column("datasetId") == datasetId)
                    .fetchAll(dbConnection)
            }

            appState.currentDataset = dataset
            appState.records = records
            // Store available column names for embedding target selection.
            appState.columnHeaders = ["textContent", "status", "duration"]
            appState.selectedColumn = "textContent"
            appState.phase = appState.hasAPIKey ? .columnSelected : .apiKeyMissing
            appState.statusMessage = "\(records.count) 件のレコードを読み込みました"
        } catch {
            appState.phase = .apiError("CSV 読み込みエラー: \(error.localizedDescription)")
            appState.statusMessage = "エラー: \(error.localizedDescription)"
        }

        appState.isProcessing = false
    }

    // MARK: - Embedding (S2 → S4)

    // Compute embeddings for all records using the OpenAI API with parallel execution.
    func runEmbedding() async {
        guard let client = openAIClient, let dataset = appState.currentDataset else { return }

        appState.isProcessing = true
        let selectedCol = appState.selectedColumn

        // Extract the text for embedding based on the user's column selection.
        let eligibleRecords = appState.records.filter { record in
            let text = textForColumn(record: record, column: selectedCol)
            return !text.isEmpty
        }
        appState.progressTotal = Double(eligibleRecords.count)
        appState.progressValue = 0
        appState.statusMessage = "埋め込みを実行中... (0/\(eligibleRecords.count))"

        do {
            guard let datasetId = dataset.id else { return }
            let db = database.writer

            // Create the embedding run metadata record.
            let embeddingRun = try await db.write { dbConnection -> EmbeddingRun in
                var run = EmbeddingRun(
                    datasetId: datasetId,
                    modelName: OpenAIClient.embeddingModel,
                    dimensions: OpenAIClient.embeddingDimensions,
                    tokenLimit: OpenAIClient.tokenLimit,
                    totalRecords: eligibleRecords.count,
                    skippedRecords: 0,
                    createdAt: Date()
                )
                try run.insert(dbConnection)
                run.id = dbConnection.lastInsertedRowID
                return run
            }

            guard let runId = embeddingRun.id else { return }

            // Build a sendable work list from eligible records.
            let workItems: [(id: Int64, text: String)] = eligibleRecords.compactMap { r in
                guard let rid = r.id else { return nil }
                return (id: rid, text: textForColumn(record: r, column: selectedCol))
            }

            // Parallel processing with rate-limit-aware batching.
            // Strategy: fire full batches concurrently, then check headers after each batch
            // to decide the next batch size. No per-request stagger — let HTTP pipelining work.
            var allEmbeddings: [(recordId: Int64, vector: [Float])] = []
            var cursor = 0
            // Start aggressively; the API will tell us if we need to slow down.
            var batchSize = 20

            // Cumulative counters across all batches — never reset.
            var firstError: Error?
            var totalAttempted = 0
            var totalFailed = 0

            enum TaskResult: Sendable {
                case success(Int64, [Float])
                case failure(Error)
            }

            outerLoop: while cursor < workItems.count {
                let batchEnd = min(cursor + batchSize, workItems.count)
                let batch = Array(workItems[cursor..<batchEnd])

                let batchResults = try await withThrowingTaskGroup(
                    of: TaskResult.self
                ) { group in
                    for item in batch {
                        group.addTask {
                            var lastError: Error = OpenAIError.emptyResponse
                            for attempt in 1...3 {
                                do {
                                    let vector = try await client.fetchEmbedding(for: item.text)
                                    return .success(item.id, vector)
                                } catch {
                                    lastError = error
                                    if case OpenAIError.rateLimited = error {
                                        try? await Task.sleep(for: .seconds(Double(attempt) * 3))
                                    } else if attempt < 3 {
                                        try? await Task.sleep(for: .seconds(1))
                                    }
                                }
                            }
                            return .failure(lastError)
                        }
                    }

                    var successes: [(Int64, [Float])] = []
                    for try await result in group {
                        totalAttempted += 1
                        switch result {
                        case .success(let id, let vec):
                            successes.append((id, vec))
                        case .failure(let err):
                            totalFailed += 1
                            if firstError == nil { firstError = err }
                        }
                        // Cumulative progress — monotonically increasing.
                        appState.progressValue = Double(totalAttempted)
                        let pct = workItems.count > 0
                            ? Int(Double(totalAttempted) / Double(workItems.count) * 100) : 0
                        let failInfo = totalFailed > 0 ? " 失敗:\(totalFailed)" : ""
                        appState.statusMessage =
                            "埋め込み実行中... \(totalAttempted)/\(workItems.count) (\(pct)%)\(failInfo)"
                        await Task.yield()
                    }
                    return successes
                }

                allEmbeddings.append(contentsOf: batchResults)
                cursor = batchEnd

                // Fail fast: if the first batch all failed, abort with clear error.
                if cursor >= batch.count && allEmbeddings.isEmpty && totalFailed >= batch.count {
                    break outerLoop
                }

                let nextConcurrency = await client.recommendedConcurrency
                batchSize = max(1, nextConcurrency)
            }

            // If everything failed, surface the error instead of silently completing.
            if allEmbeddings.isEmpty {
                let msg = firstError?.localizedDescription ?? "原因不明"
                appState.phase = .apiError("埋め込みが 0 件でした: \(msg)")
                appState.statusMessage = "埋め込み失敗: \(msg)"
                appState.isProcessing = false
                return
            }
            if totalFailed > 0 {
                appState.statusMessage = "\(totalFailed) 件の失敗を除き埋め込み完了"
            }

            // Batch-insert all embedding vectors into the database.
            let embeddingsToSave = allEmbeddings
            try await db.write { dbConnection in
                for (recordId, vector) in embeddingsToSave {
                    var embedding = Embedding(
                        embeddingRunId: runId,
                        recordId: recordId,
                        vector: Embedding.vectorData(from: vector)
                    )
                    try embedding.insert(dbConnection)
                }
            }

            appState.currentEmbeddingRun = embeddingRun
            appState.phase = .embeddingComplete
            appState.statusMessage = "埋め込み完了: \(allEmbeddings.count) 件処理済み"
        } catch {
            appState.phase = .apiError("��め込みエラー: \(error.localizedDescription)")
            appState.statusMessage = "エラー: \(error.localizedDescription)"
        }

        appState.isProcessing = false
    }

    // MARK: - Clustering (S4 → S5)

    // Run the selected clustering algorithm on the stored embedding vectors.
    func runClustering() async {
        guard let embeddingRun = appState.currentEmbeddingRun,
              let dataset = appState.currentDataset else { return }

        appState.isProcessing = true
        appState.statusMessage = "クラスタリングを実行中..."

        do {
            guard let runId = embeddingRun.id else { return }
            let db = database.writer

            // Load all embedding vectors from the database.
            let embeddings = try await db.read { dbConnection in
                try Embedding
                    .filter(Column("embeddingRunId") == runId)
                    .fetchAll(dbConnection)
            }

            let vectors = embeddings.map { $0.toFloatArray() }
            let recordIds = embeddings.map { $0.recordId }

            guard !vectors.isEmpty else {
                appState.statusMessage = "埋め込みデータがありません"
                appState.isProcessing = false
                return
            }

            // Execute the selected clustering algorithm OFF the main actor
            // so UI stays responsive and the watchdog does not kill the app.
            let method = appState.clusteringMethod
            let kVal = appState.kValue
            let eps = appState.epsilon
            let minSamp = appState.minSamples

            appState.statusMessage = "クラスタリング計算中... (500件)"

            let (labels, clusterCount, parametersJSON) = await Task.detached(priority: .userInitiated) {
                () -> ([Int], Int, String) in
                switch method {
                case .kMeansPlusPlus:
                    let l = KMeansPlusPlus.cluster(vectors: vectors, k: kVal)
                    return (l, kVal, "{\"k\":\(kVal)}")
                case .dbscan:
                    let l = DBSCAN.cluster(vectors: vectors, epsilon: eps, minSamples: minSamp)
                    let count = Set(l.filter { $0 >= 0 }).count
                    return (l, count, "{\"epsilon\":\(eps),\"minSamples\":\(minSamp)}")
                }
            }.value

            // Defensive: labels must match vectors length.
            guard labels.count == recordIds.count else {
                appState.statusMessage = "クラスタリング結果の不整合"
                appState.isProcessing = false
                return
            }

            // Store clustering results in the database.
            guard let datasetId = dataset.id, let embeddingRunId = embeddingRun.id else { return }
            let methodRaw = method.rawValue

            let (savedRun, assignments) = try await db.write { dbConnection -> (ClusteringRun, [ClusterAssignment]) in
                var cRun = ClusteringRun(
                    datasetId: datasetId,
                    embeddingRunId: embeddingRunId,
                    method: methodRaw,
                    parameters: parametersJSON,
                    clusterCount: clusterCount,
                    createdAt: Date()
                )
                try cRun.insert(dbConnection)
                let cRunId = dbConnection.lastInsertedRowID
                cRun.id = cRunId

                var savedAssignments: [ClusterAssignment] = []
                for (index, label) in labels.enumerated() {
                    var assignment = ClusterAssignment(
                        clusteringRunId: cRunId,
                        recordId: recordIds[index],
                        clusterLabel: label
                    )
                    try assignment.insert(dbConnection)
                    savedAssignments.append(assignment)
                }
                return (cRun, savedAssignments)
            }

            appState.currentClusteringRun = savedRun
            appState.clusterAssignments = assignments
            appState.topics = [] // Clear stale topics from previous runs.
            appState.phase = .clusteringComplete
            appState.statusMessage = "クラスタリング完了: \(clusterCount) クラスター"
        } catch {
            appState.phase = .apiError("クラスタリングエラー: \(error.localizedDescription)")
        }

        appState.isProcessing = false
    }

    // MARK: - UMAP (runs after embedding, independent of clustering)

    // Run simplified UMAP to produce 3D coordinates for visualization.
    func runUMAP() async {
        guard let embeddingRun = appState.currentEmbeddingRun else { return }

        appState.isProcessing = true
        appState.statusMessage = "UMAP を実行中..."

        do {
            guard let runId = embeddingRun.id else { return }
            let db = database.writer

            let embeddings = try await db.read { dbConnection in
                try Embedding
                    .filter(Column("embeddingRunId") == runId)
                    .fetchAll(dbConnection)
            }

            let vectors = embeddings.map { $0.toFloatArray() }
            let recordIds = embeddings.map { $0.recordId }

            guard !vectors.isEmpty else {
                appState.statusMessage = "埋め込みデータがありません"
                appState.isProcessing = false
                return
            }

            // Build per-point cluster labels for supervised UMAP (if clustering is done).
            let assignments = appState.clusterAssignments
            let labelByRecordId = Dictionary(uniqueKeysWithValues: assignments.map { ($0.recordId, $0.clusterLabel) })
            let labels: [Int]? = assignments.isEmpty ? nil : recordIds.map { labelByRecordId[$0] ?? -1 }

            appState.statusMessage = "PCA 計算中..."

            // Run PCA + centroid scaling OFF the main actor.
            let coords3D = await Task.detached(priority: .userInitiated) {
                SimpleUMAP.reduce(vectors: vectors, labels: labels, outputDimensions: 3)
            }.value

            // Defensive: coordinates must match recordIds length.
            guard coords3D.count == recordIds.count else {
                appState.statusMessage = "UMAP 結果の不整合 (coords: \(coords3D.count), records: \(recordIds.count))"
                appState.isProcessing = false
                return
            }

            // Store UMAP results in the database.
            let parametersJSON = "{\"n_neighbors\":10,\"n_epochs\":800,\"supervised\":\(labels != nil)}"
            guard let embeddingRunId = embeddingRun.id else { return }

            let savedCoords = try await db.write { dbConnection -> [DimensionReductionCoord] in
                var reduction = DimensionReduction(
                    embeddingRunId: embeddingRunId,
                    method: "UMAP",
                    parameters: parametersJSON,
                    createdAt: Date()
                )
                try reduction.insert(dbConnection)
                let reductionId = dbConnection.lastInsertedRowID

                var result: [DimensionReductionCoord] = []
                for (index, coord) in coords3D.enumerated() {
                    guard index < recordIds.count, coord.count >= 3 else { continue }
                    var c = DimensionReductionCoord(
                        reductionId: reductionId,
                        recordId: recordIds[index],
                        x: coord[0],
                        y: coord[1],
                        z: coord[2]
                    )
                    try c.insert(dbConnection)
                    result.append(c)
                }
                return result
            }

            appState.coordinates = savedCoords
            appState.statusMessage = "UMAP 完了: 3D 座標を生成しました"
        } catch {
            appState.statusMessage = "UMAP エラー: \(error.localizedDescription)"
        }

        appState.isProcessing = false
    }

    // MARK: - Topic Generation (S5 → S6)

    // Generate LLM topic summaries for each cluster using sequential processing.
    func generateTopics() async {
        guard let client = openAIClient,
              let clusteringRun = appState.currentClusteringRun,
              let embeddingRun = appState.currentEmbeddingRun else { return }

        appState.isProcessing = true
        appState.statusMessage = "トピックを生成中..."

        do {
            guard let embRunId = embeddingRun.id, let clRunId = clusteringRun.id else { return }
            let db = database.writer

            let embeddings = try await db.read { dbConnection in
                try Embedding
                    .filter(Column("embeddingRunId") == embRunId)
                    .fetchAll(dbConnection)
            }

            // Build a lookup from record ID to embedding vector.
            let vectorByRecordId = Dictionary(
                uniqueKeysWithValues: embeddings.map { ($0.recordId, $0.toFloatArray()) }
            )

            // Prepare grounding: sample records and ask LLM to characterize the dataset first.
            let records = appState.records
            let assignments = appState.clusterAssignments
            let groundingSample = Array(records.shuffled().prefix(20))
            let sampleText: String = groundingSample.enumerated().map { index, record -> String in
                let preview = String(record.textContent.prefix(150))
                return String(index + 1) + ". " + preview + "..."
            }.joined(separator: "\n")

            appState.statusMessage = "データセットの特徴を分析中..."

            // Step 1: Ask LLM to infer what this dataset is about from the random sample.
            let datasetDescription = try await client.fetchCompletion(
                systemPrompt: "あなたはデータ分析の専門家です。",
                userPrompt: """
                以下はあるデータセットからランダムに抽出した20件のテキストデータです。
                このデータセットが何のデータか、どのような業務・文脈のものか、
                100文字以内で推定して説明してください。

                \(sampleText)

                出力形式:
                データセットの説明: ...
                """
            )

            // Build the grounding text with the dataset characterization.
            let groundingText = """
            【データセットの特徴】
            \(datasetDescription)

            【サンプルデータ（20件）】
            \(sampleText)
            """

            // Process clusters from largest to smallest so that larger clusters
            // claim their topic names first. Smaller clusters with duplicates get regenerated.
            let clusterSizes = Dictionary(grouping: assignments, by: \.clusterLabel)
                .filter { $0.key >= 0 }
                .mapValues(\.count)
            let sortedLabels = clusterSizes.keys.sorted { clusterSizes[$0]! > clusterSizes[$1]! }

            var generatedTopics: [Topic] = []

            for label in sortedLabels {
                let clusterRecordIds = Set(
                    assignments.filter { $0.clusterLabel == label }.map(\.recordId)
                )
                let clusterRecords = records.filter { r in
                    guard let rid = r.id else { return false }
                    return clusterRecordIds.contains(rid)
                }

                let representatives = extractRepresentatives(
                    records: clusterRecords,
                    vectorByRecordId: vectorByRecordId,
                    count: 5
                )

                // Generate topic, then check for duplicate names.
                // If a duplicate is found, regenerate with explicit differentiation instructions.
                var response = try await client.fetchCompletion(
                    systemPrompt: buildSystemPrompt(groundingText: groundingText, priorTopics: generatedTopics),
                    userPrompt: buildUserPrompt(representatives: representatives)
                )

                let maxRetries = 2
                for retry in 1...maxRetries {
                    let newName = extractTopicNameFromResponse(response)
                    let duplicate = generatedTopics.first { existingTopic in
                        let existingName = extractTopicNameFromResponse(existingTopic.topicText)
                        return !existingName.isEmpty && existingName == newName
                    }

                    guard let dup = duplicate else { break } // No duplicate, done.

                    // Duplicate found: regenerate with explicit differentiation.
                    appState.statusMessage = "トピック重複検出 — 再生成中 (\(retry)/\(maxRetries))..."

                    // Find representative records from the duplicate cluster for contrast.
                    let dupRecordIds = Set(
                        assignments.filter { $0.clusterLabel == dup.clusterLabel }.map(\.recordId)
                    )
                    let dupRecords = records.filter { r in
                        guard let rid = r.id else { return false }
                        return dupRecordIds.contains(rid)
                    }
                    let dupRepresentatives = extractRepresentatives(
                        records: dupRecords,
                        vectorByRecordId: vectorByRecordId,
                        count: 3
                    )

                    response = try await client.fetchCompletion(
                        systemPrompt: buildSystemPrompt(groundingText: groundingText, priorTopics: generatedTopics),
                        userPrompt: buildDifferentiationPrompt(
                            representatives: representatives,
                            duplicateTopicName: newName,
                            duplicateRepresentatives: dupRepresentatives
                        )
                    )
                }

                let representativeIdStrings = representatives.compactMap { $0.id.map(String.init) }
                let idsJSON = "[" + representativeIdStrings.joined(separator: ",") + "]"

                let finalResponse = response
                let topic = try await db.write { dbConnection -> Topic in
                    var t = Topic(
                        clusteringRunId: clRunId,
                        clusterLabel: label,
                        topicText: finalResponse,
                        representativeIds: idsJSON,
                        modelName: OpenAIClient.completionModel,
                        createdAt: Date()
                    )
                    try t.insert(dbConnection)
                    return t
                }

                generatedTopics.append(topic)
                appState.statusMessage = "トピック生成中... (\(generatedTopics.count)/\(sortedLabels.count))"
            }

            appState.topics = generatedTopics
            appState.phase = .allComplete
            appState.statusMessage = "完了: \(generatedTopics.count) クラスターのトピックを生成しました"
        } catch {
            appState.phase = .apiError("トピック生成エラー: \(error.localizedDescription)")
        }

        appState.isProcessing = false
    }

    // MARK: - Private Helpers

    // Select the N records closest to the cluster centroid by cosine distance.
    private func extractRepresentatives(
        records: [TranscriptRecord],
        vectorByRecordId: [Int64: [Float]],
        count: Int
    ) -> [TranscriptRecord] {
        let vectors = records.compactMap { r -> [Float]? in
            guard let rid = r.id else { return nil }
            return vectorByRecordId[rid]
        }
        guard !vectors.isEmpty else { return Array(records.prefix(count)) }

        let dimensions = vectors[0].count
        var centroid = [Float](repeating: 0, count: dimensions)
        for vector in vectors {
            for i in 0..<dimensions { centroid[i] += vector[i] }
        }
        let n = Float(vectors.count)
        for i in 0..<dimensions { centroid[i] /= n }

        let ranked = records.compactMap { record -> (TranscriptRecord, Float)? in
            guard let rid = record.id, let vector = vectorByRecordId[rid] else { return nil }
            let distance = cosineDistance(vector, centroid)
            return (record, distance)
        }.sorted { $0.1 < $1.1 }

        return Array(ranked.prefix(count).map(\.0))
    }

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 1.0 }
        return 1.0 - (dotProduct / denominator)
    }

    private func buildSystemPrompt(groundingText: String, priorTopics: [Topic]) -> String {
        var prompt = """
        あなたは電話応対データの分析アシスタントです。
        以下はデータセット全体のランダムサンプルです。全体の傾向を把握してください。
        ---
        \(groundingText)
        ---
        """

        if !priorTopics.isEmpty {
            prompt += "\n\n以下は他のクラスターに付与済みのトピックです。"
            prompt += "\n今回のクラ���ターはこれらとは異なる特徴を持っています。重複しない観点で要約してください。\n"
            for topic in priorTopics {
                prompt += "- クラスター\(topic.clusterLabel): \(topic.topicText)\n"
            }
        }

        return prompt
    }

    private func buildUserPrompt(representatives: [TranscriptRecord]) -> String {
        let recordTexts = representatives.enumerated().map { index, record in
            let text = String(record.textContent.prefix(2000))
            return "\(index + 1). \(text)"
        }.joined(separator: "\n\n")

        return """
        以下はあるクラスターの代表的な電話応対記録です。

        代表データ:
        \(recordTexts)

        上記データの共通点を分析し、トピック名と説明を付けてください。

        重要な指示:
        - トピック名は抽象的な表現（「問い合わせ対応」「確認連絡」等）を避けてください
        - データに出てくる具体的なキーワード（商品名、手続き名、エラー名、操作内容など）を必ずトピック名に含めてください
        - 例: ✕「確認の電話」→ ○「振込エラー後の再手続き案内」
        - 例: ✕「情報提供」→ ○「試験日程の変更連絡」
        - トピック名は20文字以内、説明文は100文字以内

        出力形式:
        トピック名: ...
        説明: ...
        """
    }

    // Extract the text value from a record for the specified column name.
    private func textForColumn(record: TranscriptRecord, column: String) -> String {
        switch column {
        case "textContent": return record.textContent
        case "status": return record.status ?? ""
        case "duration": return record.duration ?? ""
        case "datetime": return record.datetime ?? ""
        case "originalNo": return record.originalNo
        default: return record.textContent
        }
    }

    // Extract topic name from the LLM response text (e.g. "トピック名: Foo").
    private func extractTopicNameFromResponse(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("トピック名:") || trimmed.hasPrefix("トピック名：") {
                return trimmed
                    .replacingOccurrences(of: "トピック名:", with: "")
                    .replacingOccurrences(of: "トピック名：", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // Build a prompt that explicitly contrasts this cluster against one with the same topic name.
    // Provides representative data from both clusters so the LLM can identify the difference.
    private func buildDifferentiationPrompt(
        representatives: [TranscriptRecord],
        duplicateTopicName: String,
        duplicateRepresentatives: [TranscriptRecord]
    ) -> String {
        let thisTexts = representatives.enumerated().map { i, r in
            String(i + 1) + ". " + String(r.textContent.prefix(1500))
        }.joined(separator: "\n\n")

        let dupTexts = duplicateRepresentatives.enumerated().map { i, r in
            String(i + 1) + ". " + String(r.textContent.prefix(800))
        }.joined(separator: "\n\n")

        return """
        別のクラスターに「\(duplicateTopicName)」というトピック名が既に割り当てられています。
        今回のクラスターには、それとは異なるトピック名を付けてください。

        ===== 既に「\(duplicateTopicName)」が割り当てられたクラスターの代表データ =====
        \(dupTexts)

        ===== 今回のクラスターの代表データ =====
        \(thisTexts)

        上の2つのクラスターの違いに注目し、今回のクラスターに固有の特徴を表す
        トピック名（20文字以内）と説明文（100文字以内）を付けてください。
        「\(duplicateTopicName)」とは明確に異なる名前にしてください。

        出力形式:
        トピック名: ...
        説明: ...
        """
    }
}
