# SDD Demo Project Conventions

## Specification-Driven Development (SDD)
- Specifications are the single source of truth — not implementation
- All decisions must be documented in writing (no verbal-only decisions)
- Progressive refinement: coarse to fine granularity across phases

## Development Phases
1. Concept — problem domain, business value, constraints
2. Specification — behavior-based requirements, use cases, I/O definitions
3. Design — architecture, data model, interface definitions
4. Task Breakdown — implementation units, dependencies, estimates
5. Scheduling — milestones, priorities, risk buffers

## Documentation Rules
- All documents stored in `Docs/` folder as Markdown (.md) files
- Filenames prefixed with sequential numbers (e.g., `001_CTO_Project_Planning.md`)
- Version control via filename suffix (v1, v2, ...) — document numbers are fixed, versions increment
- Changes tracked as new versions of existing documents or new numbered documents
- Reviews and opinions delivered as downloadable MD files

## Communication Rules
- All instructions and reviews recorded in Markdown format
- No decisions made via chat-only — everything must be documented
- Changes must be trackable as diffs

## Product Specification (Agreed in Specification Phase — v4)
- Deliverable: macOS signed app (.app), notarized, distributed via internal bulletin board
- Target OS: macOS Tahoe 26+
- Pipeline: CSV → Embedding → Clustering → Topic Generation → Display (with 3D visualization)
- Token limit: 8K (1 char ≈ 1 token approximation for Japanese, rear truncation)
- Demo-first: simplicity and reproducibility over strict accuracy
- Data: `Data/文字起こし結果_masked.csv` (500 phone transcript records, masked)
- UI: Menu-driven 2-window architecture (data table + analysis tabs)
- Topic generation: dataset characterization grounding, duplicate detection, anti-abstraction prompting

## Design Decisions (Confirmed in Design Phase — v2)
- Architecture: 4-layer (Presentation/Application/Domain/Infrastructure)
- UI: SwiftUI + SceneKit (3D visualization), menu-bar driven, 2 windows
- DB: SQLite via GRDB.swift, vectors stored as BLOB
- Numerical computation: Accelerate framework + LAPACK (PCA eigendecomposition)
- 3D coordinates: PCA + cluster centroid scaling (simplified UMAP abandoned due to quality issues)
- Clustering: k-means++ and DBSCAN (user selectable)
- Embedding: OpenAI text-embedding-3-small fixed (1,536 dim) — no model selection UI
- Topic LLM: gpt-4o-mini fixed — no model selection UI
- Concurrency: Swift Structured Concurrency (TaskGroup, adaptive rate-limit-aware batching)
- External dependencies: GRDB.swift only (minimize third-party risk)
- Distribution: Developer ID signed + Notarized .app, via internal bulletin board
- Entitlements: network.client, files.user-selected.read-only, app-sandbox
- API key storage: macOS Keychain (not UserDefaults)

## Implementation (ClusterInsight App)
- Source: `ClusterInsight/Sources/` (24 Swift files, 3,012 lines, 4-layer architecture)
- Project: `ClusterInsight/project.yml` → xcodegen → `ClusterInsight.xcodeproj`
- Build: `xcodebuild build -project ClusterInsight.xcodeproj -scheme ClusterInsight`
- External dependency: GRDB.swift (SPM)
- App name: ClusterInsight

## Feedback Loop Rules
- Default: waterfall progression
- Minor issues: fix in current phase
- Major issues: return to prior phase with documented justification
- All feedback must be in writing (Markdown)

## Roles
- CTO (AI assistant: ChatGPT) — specification design, policy decisions
- Senior Engineer (AI assistant: Claude) — implementation, technical review
- Claude's role: review CTO directives from an implementation perspective, flag infeasibility, suggest efficient alternatives
