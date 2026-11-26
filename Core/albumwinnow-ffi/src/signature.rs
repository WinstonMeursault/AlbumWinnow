use crate::{
    BridgeError,
    matching::CoreMatch,
    scan::{CoreAssetKey, CoreComparisonSides},
    scene::CoreSceneProvider,
};
use albumwinnow_core::signature::{SignatureEdge, SignatureEvidence, SignatureMember};
#[derive(uniffi::Record)]
pub struct CoreSignatureMember {
    pub asset: CoreAssetKey,
    pub revision: String,
    pub properties: Option<u8>,
}
#[derive(uniffi::Record)]
pub struct CoreSignatureEdge {
    pub first: CoreAssetKey,
    pub second: CoreAssetKey,
    pub kind: CoreMatch,
}
#[uniffi::export]
pub fn core_review_signature(
    members: Vec<CoreSignatureMember>,
    edges: Vec<CoreSignatureEdge>,
    sides: Option<CoreComparisonSides>,
    scene: Option<CoreSceneProvider>,
) -> Result<String, BridgeError> {
    let evidence = SignatureEvidence {
        members: members
            .into_iter()
            .map(|m| SignatureMember {
                id: m.asset.into(),
                revision: m.revision,
                properties: m.properties,
            })
            .collect(),
        edges: edges
            .into_iter()
            .map(|e| SignatureEdge {
                first: e.first.into(),
                second: e.second.into(),
                kind: e.kind.into(),
            })
            .collect(),
        sides: sides.map(|s| albumwinnow_core::scan::ComparisonSides {
            first: s.first,
            second: s.second,
        }),
        scene: scene.map(Into::into),
    };
    Ok(evidence.digest()?)
}
