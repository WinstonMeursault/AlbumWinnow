use crate::{
    CoreError,
    matching::MatchKind,
    model::{AssetId, SceneProvider},
    scan::ComparisonSides,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap, HashSet};

#[derive(Clone, Debug)]
pub struct SignatureMember {
    pub id: AssetId,
    pub revision: String,
    /// None is unknown; bits 0..2 are live photo, edits and alternate photo.
    pub properties: Option<u8>,
}
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct SignatureEdge {
    pub first: AssetId,
    pub second: AssetId,
    pub kind: MatchKind,
}
pub struct SignatureEvidence {
    pub members: Vec<SignatureMember>,
    pub edges: Vec<SignatureEdge>,
    pub sides: Option<ComparisonSides>,
    pub scene: Option<SceneProvider>,
}
fn string(bytes: &mut Vec<u8>, value: &str) -> Result<(), CoreError> {
    if bytes
        .len()
        .checked_add(value.len())
        .and_then(|length| length.checked_add(4))
        .is_none_or(|length| length > 64 * 1024 * 1024)
    {
        return Err(CoreError::InvalidBuffer);
    }
    let length = u32::try_from(value.len()).map_err(|_| CoreError::InvalidBuffer)?;
    bytes.extend_from_slice(&length.to_le_bytes());
    bytes.extend_from_slice(value.as_bytes());
    Ok(())
}
fn asset(bytes: &mut Vec<u8>, id: &AssetId) -> Result<(), CoreError> {
    string(bytes, &id.source_id)?;
    string(bytes, &id.item_id)
}
fn kind_tag(kind: MatchKind) -> u8 {
    match kind {
        MatchKind::ExactDuplicate => 1,
        MatchKind::VisualDuplicate => 2,
        MatchKind::SimilarPhoto => 3,
        MatchKind::SceneSimilar => 4,
        MatchKind::Distinct => 5,
    }
}
impl SignatureEvidence {
    /// v2 canonical fields use UTF-8 byte lengths, little-endian fixed integers,
    /// and explicit option tags. Display order and recommendations are excluded.
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, CoreError> {
        if self.members.len() < 2 || self.members.len() > 100000 || self.edges.len() > 1600000 {
            return Err(CoreError::InvalidValue);
        }
        let mut members = self.members.iter().collect::<Vec<_>>();
        members.sort_by(|a, b| a.id.cmp(&b.id));
        let mut ids = HashSet::new();
        for member in &members {
            member.id.validate()?;
            if member.revision.len() > 8192
                || member.properties.is_some_and(|bits| bits > 7)
                || !ids.insert(&member.id)
            {
                return Err(CoreError::InvalidValue);
            }
        }
        if let Some(sides) = &self.sides
            && (sides.first == sides.second
                || sides.first.is_empty()
                || sides.second.is_empty()
                || sides.first.len() > 4096
                || sides.second.len() > 4096
                || members
                    .iter()
                    .any(|m| m.id.source_id != sides.first && m.id.source_id != sides.second))
        {
            return Err(CoreError::InvalidValue);
        }
        if let Some(provider) = &self.scene {
            provider.validate()?;
        }
        let mut edges = BTreeSet::new();
        for edge in &self.edges {
            if edge.first == edge.second
                || !ids.contains(&edge.first)
                || !ids.contains(&edge.second)
            {
                return Err(CoreError::InvalidValue);
            }
            let (a, b) = if edge.first < edge.second {
                (&edge.first, &edge.second)
            } else {
                (&edge.second, &edge.first)
            };
            if edge.kind == MatchKind::SceneSimilar && self.scene.is_none() {
                return Err(CoreError::InvalidValue);
            }
            edges.insert((a, b, kind_tag(edge.kind)));
        }
        // Exact byte equality is transitive; rotating its representative must not
        // invalidate a decision. Scope-bound groups still encode their real edges.
        let omit_exact_edges = self.sides.is_none()
            && !edges.is_empty()
            && edges.iter().all(|(_, _, kind)| *kind == 1);
        if omit_exact_edges {
            let mut neighbors: HashMap<&AssetId, Vec<&AssetId>> = HashMap::new();
            for (a, b, _) in &edges {
                neighbors.entry(*a).or_default().push(*b);
                neighbors.entry(*b).or_default().push(*a);
            }
            let mut connected = HashSet::new();
            let mut pending = vec![&members[0].id];
            while let Some(id) = pending.pop() {
                if connected.insert(id) {
                    pending.extend(neighbors.get(id).into_iter().flatten().copied());
                }
            }
            if connected.len() != members.len() {
                return Err(CoreError::InvalidValue);
            }
        }
        let mut bytes = b"AlbumWinnow.v2.review-signature\0".to_vec();
        bytes.extend_from_slice(&1_u16.to_le_bytes()); // Canonical format.
        bytes.extend_from_slice(&1_u16.to_le_bytes()); // Decision/matching semantics.
        bytes.extend_from_slice(&(members.len() as u32).to_le_bytes());
        for member in members {
            asset(&mut bytes, &member.id)?;
            string(&mut bytes, &member.revision)?;
            match member.properties {
                None => bytes.push(0),
                Some(bits) => {
                    bytes.push(1);
                    bytes.push(bits);
                }
            }
        }
        bytes.push(u8::from(self.sides.is_some()));
        if let Some(sides) = &self.sides {
            string(&mut bytes, &sides.first)?;
            string(&mut bytes, &sides.second)?;
        }
        bytes.push(u8::from(self.scene.is_some()));
        if let Some(provider) = &self.scene {
            for value in [
                &provider.provider_id,
                &provider.model_revision,
                &provider.preprocessing,
                &provider.platform_compatibility,
            ] {
                string(&mut bytes, value)?;
            }
        }
        let count = if omit_exact_edges { 0 } else { edges.len() };
        bytes.extend_from_slice(&(count as u32).to_le_bytes());
        if !omit_exact_edges {
            for (a, b, kind) in edges {
                asset(&mut bytes, a)?;
                asset(&mut bytes, b)?;
                bytes.push(kind);
            }
        }
        Ok(bytes)
    }
    pub fn digest(&self) -> Result<String, CoreError> {
        let digest = Sha256::digest(self.canonical_bytes()?);
        Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
    }
}
