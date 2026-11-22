import Foundation

struct SceneItem {
    let asset: PhotoAsset
    let evidence: PhotoEvidence
    let feature: SceneFeature
    var captureDate: Date? { asset.captureDate ?? evidence.captureDate }
}

struct SceneGrouping {
    static let maximumMembers = 24

    static func groups(_ items: [SceneItem], sides: ComparisonSides?, progress: (Int) -> Void) throws -> [DuplicateGroup] {
        let ordered = items.sorted {
            switch ($0.captureDate, $1.captureDate) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return precedes($0.asset.id, $1.asset.id)
            }
        }
        var candidates = SceneCandidates()
        var assigned: [Int: Int] = [:]
        var groups: [[Int]] = []
        var evidence: [[SceneMatchEvidence]] = []
        for (position, item) in ordered.enumerated() {
            try Task.checkCancellation()
            if position.isMultiple(of: 32) { progress(position) }
            let nearby = candidates.candidates(for: item.feature, asset: item.asset, date: item.captureDate)
            defer { candidates.insert(item.feature, asset: item.asset, at: position, date: item.captureDate) }
            for candidate in nearby {
                try Task.checkCancellation()
                let other = ordered[candidate]
                guard sides?.permits(item.asset.id, other.asset.id) ?? true,
                      let edge = try item.feature.match(to: other.feature, first: item.asset, second: other.asset) else { continue }
                if let group = assigned[candidate] {
                    guard groups[group].count < maximumMembers else { continue }
                    var actual: [SceneMatchEvidence] = []
                    var consistent = true
                    for member in groups[group] {
                        try Task.checkCancellation()
                        let other = ordered[member]
                        guard let match = try item.feature.match(to: other.feature, first: item.asset, second: other.asset) else {
                            consistent = false
                            break
                        }
                        if sides?.permits(item.asset.id, other.asset.id) ?? true { actual.append(match) }
                    }
                    guard consistent, !actual.isEmpty else { continue }
                    groups[group].append(position)
                    evidence[group].append(contentsOf: actual)
                    assigned[position] = group
                } else {
                    let group = groups.count
                    groups.append([candidate, position])
                    evidence.append([edge])
                    assigned[candidate] = group
                    assigned[position] = group
                }
                break
            }
        }
        progress(ordered.count)
        return groups.enumerated().map { index, members in
            let reference = ordered[members[0]]
            let matches = evidence[index]
            var group = DuplicateGroup(preferred: reference.asset, duplicates: members.dropFirst().map {
                let asset = ordered[$0].asset
                return DuplicateMember(asset: asset, match: matches.contains { $0.edge.connects(reference.asset.id, asset.id) } ? .sceneSimilar : .distinct)
            }, preferredDimensions: ImageDimensions(width: reference.evidence.width, height: reference.evidence.height))
            group.sceneAlgorithm = SceneFeature.version
            group.sceneEvidence = matches
            group.edges = matches.map(\.edge)
            group.comparisonSides = sides
            group.evidence = Dictionary(uniqueKeysWithValues: members.map { (ordered[$0].asset.id, ordered[$0].evidence) })
            group.sceneQuality = Dictionary(uniqueKeysWithValues: members.map { (ordered[$0].asset.id, ordered[$0].feature.quality) })
            group.hasQualityRecommendation = false
            for candidate in members {
                let item = ordered[candidate]
                let others = members.filter { $0 != candidate }.map { ordered[$0] }
                if let reason = recommendation(item, against: others) {
                    group.recommendedID = item.asset.id
                    group.sceneRecommendationReason = reason
                    group.hasQualityRecommendation = true
                    break
                }
            }
            return group
        }
    }

    private static func recommendation(_ item: SceneItem, against others: [SceneItem]) -> RecommendationReason? {
        if item.asset.photoProperties?.hasAssociatedResources == true,
           others.allSatisfy({ $0.asset.photoProperties?.hasAssociatedResources != true }) { return .associatedResources }
        let quality = item.feature.quality
        let othersQuality = others.map(\.feature.quality)
        let clipping = quality.darkClipping + quality.brightClipping
        let comparable = others.allSatisfy {
            abs(Double($0.evidence.width) / Double($0.evidence.height) - Double(item.evidence.width) / Double(item.evidence.height)) < 0.01 &&
                $0.evidence.width == item.evidence.width && $0.evidence.height == item.evidence.height
        }
        guard comparable else { return nil }
        if quality.focusEnergy >= 0.002, othersQuality.allSatisfy({
            quality.focusEnergy >= 1.6 * $0.focusEnergy && quality.focusEnergy - $0.focusEnergy >= 0.002 &&
            abs(quality.meanLuminance - $0.meanLuminance) <= 0.1 &&
            abs(clipping - $0.darkClipping - $0.brightClipping) <= 0.05
        }) { return .focusSignal }
        if (0.2...0.8).contains(quality.meanLuminance), othersQuality.allSatisfy({
            $0.darkClipping + $0.brightClipping - clipping >= 0.15 && quality.focusEnergy >= 0.9 * $0.focusEnergy
        }) { return .exposureSignal }
        return nil
    }

    private static func precedes(_ a: AssetID, _ b: AssetID) -> Bool {
        a.source == b.source ? a.item < b.item : a.source < b.source
    }
}
