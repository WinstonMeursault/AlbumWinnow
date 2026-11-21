import AlbumWinnowCore
import SwiftUI

struct ResultFiltersView: View {
    let model: ReviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Review Status", selection: binding(\.status)) {
                    ForEach(ReviewStatusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("result-status-filter")
                Picker("Match Category", selection: binding(\.match)) {
                    Text("All Categories").tag(nil as DuplicateMatch?)
                    ForEach([DuplicateMatch.exactDuplicate, .visualDuplicate, .similarPhoto], id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
                Picker("Source", selection: binding(\.source)) {
                    Text("All Sources").tag(nil as String?)
                    Text("Photos").tag(Optional("photos-library"))
                    ForEach(model.folders) { Text($0.name).tag(Optional($0.id)) }
                    if let source = model.resultQuery.source, source != "photos-library",
                       !model.folders.contains(where: { $0.id == source }) {
                        Text("Unavailable Source").tag(Optional(source))
                    }
                }
                Picker("Sort", selection: binding(\.sort)) {
                    ForEach(ReviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("result-sort")
                Text("Dates use the latest known capture metadata in each group. Unknown dates stay last in either direction. Size sorting uses known candidate bytes; partial sizes are lower bounds.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Filters") { model.setResultQuery(ReviewResultQuery()) }
                Text("Filtering never clears confirmed cleanup candidates. A review session keeps its current order until you return to the overview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .disabled(!model.canEditSources)
            .navigationTitle("Filter and Sort")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 500, minHeight: 400, idealHeight: 520)
        #endif
    }

    private func binding<Value>(_ path: WritableKeyPath<ReviewResultQuery, Value>) -> Binding<Value> {
        Binding(get: { model.resultQuery[keyPath: path] }, set: {
            var query = model.resultQuery
            query[keyPath: path] = $0
            model.setResultQuery(query)
        })
    }
}

struct GroupInformationView: View {
    let model: ReviewModel
    let group: DuplicateGroup
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReviewModel.showReviewFilenamesKey) private var showFilenames = false

    var body: some View {
        NavigationStack {
            List {
                Section("Recommendation Evidence") {
                    let reasons = group.recommendationReasons
                    ForEach(Array(reasons.prefix(2)), id: \.self) { Text(reason($0)) }
                    if reasons.count > 2 {
                        DisclosureGroup("More Evidence") {
                            ForEach(Array(reasons.dropFirst(2)), id: \.self) { Text(reason($0)) }
                        }
                    }
                    Text("Recommended is a suggestion. Selected is your keep choice. Locked photos must also remain; a lock is not a quality rating.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Why These Photos Are Grouped") {
                    Text(group.match.title).font(.headline)
                    Text(group.match.explanation)
                    if group.comparisonSides != nil {
                        Text("Only cross-side edges are evidence. Photos on the same side are not assumed identical. Choosing one photo may retain additional members without a verified match to a retained photo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The summary uses the most cautious category. Each member below records its own match to the reference photo, not to every other member.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(group.duplicates.enumerated()), id: \.element.id) { index, member in
                        LabeledContent(showFilenames ? member.asset.name : "Photo \(index + 2)") {
                            Text(member.match.title)
                        }
                    }
                    Text("Reference: \(showFilenames ? group.preferred.name : String(localized: "Photo 1"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Photo Metadata") {
                    ForEach(Array(group.assets.enumerated()), id: \.element.id) { index, asset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(showFilenames ? asset.name : "Photo \(index + 1)").font(.headline)
                            Text(model.sourceLabel(asset.id.source))
                            let evidence = group.evidence?[asset.id]
                            if let evidence {
                                Text("\(evidence.width) × \(evidence.height)")
                                Text(evidence.bitDepth.map { "\($0)-bit" } ?? String(localized: "Bit depth unknown"))
                            } else { Text("Resolution and bit depth unknown") }
                            Text(asset.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Size unknown"))
                            let date = asset.captureDate ?? evidence?.captureDate
                            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Capture date unknown"))
                            if model.isLocked(asset) { Label("Locked", systemImage: "lock.fill") }
                            if model.isReadOnly(asset) { Label("Read-only Source", systemImage: "hand.raised.fill") }
                        }
                        .font(.subheadline)
                    }
                }
                Section("Candidate Resource Size") {
                    Text(group.sizeEstimate(removing: model.estimatedRemovals(for: group)).summary)
                    Text("This is not a promise of immediately released device storage. iCloud optimization and Recently Deleted affect actual free space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Zoom") {
                    Text("Double-tap or double-click a photo to zoom or reset. Use the group menu for Zoom In, Reset Zoom and Sync Zoom. Dragging while zoomed pans the image instead of changing groups.")
                    Text("Photos are linked by relative image position, not pixel alignment. Crops and different viewpoints may show different objects. Detail previews are limited to available pixels and do not silently download from iCloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review Evidence")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 600, minHeight: 400, idealHeight: 620)
        #endif
    }

    private func reason(_ reason: RecommendationReason) -> String {
        let evidence = group.evidence?[group.recommendation.id]
        switch reason {
        case .sourcePreference: return String(localized: "Quality-ranking signals are tied; the configured source preference is used.")
        case .associatedResources: return String(localized: "Associated resource flags are present. Cleanup protection applies.")
        case .higherResolution:
            guard let evidence else { return String(localized: "Resolution unknown") }
            return String(localized: "More pixels than another copy (\(evidence.width) × \(evidence.height)). Resolution alone does not establish sharpness.")
        case .higherBitDepth:
            guard let depth = evidence?.bitDepth else { return String(localized: "Bit depth unknown") }
            return String(localized: "Higher documented bit depth (\(depth)-bit) than another copy.")
        case .wideColor: return String(localized: "The decoded image has a wide-color profile.")
        case .edgeContrast: return String(localized: "A thumbnail edge-contrast tie-break is used. This is not a calibrated sharpness comparison.")
        case .noQualityAdvantage: return String(localized: "No established quality advantage. Choose according to your preference.")
        }
    }
}

extension ReviewStatusFilter {
    var title: String {
        switch self {
        case .active: String(localized: "All Except Kept")
        case .all: String(localized: "All Review States")
        case .pending: String(localized: "Needs Review")
        case .confirmed: String(localized: "Confirmed")
        case .deferred: String(localized: "Later")
        case .kept: String(localized: "Entire Group Kept")
        }
    }
}

extension ReviewSort {
    var title: String {
        switch self {
        case .stable: String(localized: "Stable Order")
        case .newest: String(localized: "Capture Date · Newest First")
        case .oldest: String(localized: "Capture Date · Oldest First")
        case .count: String(localized: "Most Photos")
        case .bytes: String(localized: "Largest Candidate Size")
        }
    }
}

extension DuplicateMatch {
    var title: String {
        switch self {
        case .exactDuplicate: String(localized: "Exact Duplicate")
        case .visualDuplicate: String(localized: "Possible Same Image")
        case .similarPhoto: String(localized: "Highly Similar · Review Differences")
        case .distinct: String(localized: "Different Photos")
        }
    }

    var explanation: String {
        switch self {
        case .exactDuplicate: String(localized: "File bytes and effective orientation agree.")
        case .visualDuplicate: String(localized: "Multi-scale image checks agree. Size, format or compression may differ.")
        case .similarPhoto: String(localized: "The overall image is close, but higher-resolution checks found local differences. Manual review is required.")
        case .distinct: String(localized: "These photos do not have a verified duplicate relationship.")
        }
    }
}

extension SizeEstimate {
    var summary: String {
        let bytes = ByteCountFormatter.string(fromByteCount: knownBytes, countStyle: .file)
        if knownCount == 0, unknownCount > 0 { return String(localized: "Size unknown") }
        if unknownCount > 0 { return String(localized: "At least \(bytes), plus \(unknownCount) photos of unknown size") }
        if overflowed { return String(localized: "At least \(bytes)") }
        return bytes
    }
}
