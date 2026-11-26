import AlbumWinnowRust
@testable import AlbumWinnowApple

extension DuplicateGroup {
    func reviewSignature() throws -> String {
        let members = assets.map { asset in
            let properties: UInt8? = asset.photoProperties.map {
                ($0.isLivePhoto ? 1 : 0) | ($0.hasEdits ? 2 : 0) | ($0.hasAlternatePhoto ? 4 : 0)
            }
            return CoreSignatureMember(asset: asset.id.coreValue, revision: asset.revision, properties: properties)
        }
        let edges = (self.edges ?? duplicates.map { MatchEdge(first: preferred.id, second: $0.asset.id, match: $0.match) })
            .map { CoreSignatureEdge(first: $0.first.coreValue, second: $0.second.coreValue, kind: $0.match.coreValue) }
        let provider = sceneAlgorithm.map { algorithm in
            var provider = SceneFeature.provider
            provider.modelRevision = algorithm
            return provider
        }
        return try coreResult {
            try coreReviewSignature(members: members, edges: edges,
                                    sides: comparisonSides.map { CoreComparisonSides(first: $0.first, second: $0.second) }, scene: provider)
        }
    }
}
