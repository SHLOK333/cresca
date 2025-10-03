use anyhow::Result;
use sled::{Db, Tree};
use std::sync::Arc;

use crate::models::{HistoricalPosition, PaginatedResponse, Position, PositionStatus, UnspentNote};

#[derive(Clone)]
pub struct Database {
    _db: Arc<Db>,
    // K: owner_pub_key (bytes), V: Vec<Position> (json)
    pub open_positions: Tree,
    // K: owner_pub_key (bytes), V: Vec<HistoricalPosition> (json)
    pub historical_positions: Tree,
    // K: receiver_hash (bytes), V: Vec<UnspentNote> (json)
    pub unspent_notes: Tree,
    // K: owner_pub_key (bytes), V: encrypted metadata (bytes)
    pub user_metadata: Tree,
    // V2: Reverse lookup for efficiency
    // K: position_id (bytes), V: owner_pub_key (bytes)
    pub position_id_to_owner: Tree,
    pub positions_by_id: Tree,
}

#[derive(serde::Serialize, serde::Deserialize, Clone)]
#[serde(tag = "status", content = "data")] 
pub enum PositionData {
    Open(Position),
    Historical(HistoricalPosition),
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let _db = Arc::new(sled::open(path)?);
        Ok(Self {
            open_positions: _db.open_tree("open_positions")?,
            historical_positions: _db.open_tree("historical_positions")?,
            unspent_notes: _db.open_tree("unspent_notes")?,
            user_metadata: _db.open_tree("user_metadata")?,
            position_id_to_owner: _db.open_tree("pos_id_to_owner")?,
            positions_by_id: _db.open_tree("positions_by_id")?, 
            _db,
        })
    }

    pub fn add_open_position(&self, owner_pub_key: &[u8], position: Position) -> Result<()> {
        let mut positions = self.get_open_positions(owner_pub_key)?;
        if !positions
            .iter()
            .any(|p| p.position_id == position.position_id)
        {
            positions.push(position.clone());
        }
        self.open_positions
            .insert(owner_pub_key, serde_json::to_vec(&positions)?)?;
        self.position_id_to_owner
            .insert(position.position_id.clone(), owner_pub_key)?;
        let data = PositionData::Open(position.clone());
        self.positions_by_id.insert(position.position_id.as_bytes(), serde_json::to_vec(&data)?)?;

        println!("positions_by_id insert {}" , position.position_id);
        // println!("Inserted position Id for {:#?} owner {:#?}" , position.position_id, hex::encode(owner_pub_key));
        Ok(())
    }

    pub fn move_to_historical(
        &self,
        position_id: &[u8],
        status: PositionStatus,
        final_pnl: String,
        owner_address: String, 
    ) -> Result<()> {
        // println!("Moving to historical records {:#?}" , format!("0x{}" , hex::encode(position_id)));
        let owner_pub_key = match self
            .position_id_to_owner
            .get(format!("0x{}", hex::encode(position_id)))?
        {
            Some(pk) => pk,
            None => return Ok(()), // Position owner not found, maybe already processed
        };

        // println!("Owner of position {:#?}" , hex::encode(&owner_pub_key));

        let mut open_positions = self.get_open_positions(&owner_pub_key)?;

        if let Some(index) = open_positions
            .iter()
            .position(|p| p.position_id.replace("0x", "") == hex::encode(position_id))
        {
            let position_to_move = open_positions.remove(index);
            // println!("Position found {}" , index);
            self.open_positions
                .insert(&owner_pub_key, serde_json::to_vec(&open_positions)?)?;

            let historical_pos = HistoricalPosition {
                position: position_to_move,
                status,
                final_pnl,
                owner_address
            };

            let mut historical_positions =
                self.get_historical_positions_internal(&owner_pub_key)?;
            historical_positions.insert(0, historical_pos.clone()); // Insert at the beginning for chronological order
            self.historical_positions
                .insert(&owner_pub_key, serde_json::to_vec(&historical_positions)?)?;

            self.position_id_to_owner
                .remove(format!("0x{}", hex::encode(position_id)))?;
            let data = PositionData::Historical(historical_pos);
            self.positions_by_id.insert(format!("0x{}", hex::encode(position_id)).as_bytes(), serde_json::to_vec(&data)?)?;

            // self.position_id_to_owner.remove()
            // println!("Removed position {:#?}" , position_id);
        }

        Ok(())
    }

    pub fn get_position_by_id(&self, position_id: &[u8]) -> Result<Option<PositionData>> {
        // println!("get position_id {}", hex::encode(position_id));
        match self.positions_by_id.get(format!("0x{}", hex::encode(position_id)).as_bytes())? {
            Some(data) => Ok(Some(serde_json::from_slice(&data)?)),
            None => Ok(None),
        }
    }

    pub fn get_open_positions(&self, owner_pub_key: &[u8]) -> Result<Vec<Position>> {
        match self.open_positions.get(owner_pub_key)? {
            Some(data) => Ok(serde_json::from_slice(&data)?),
            None => Ok(Vec::new()),
        }
    }

    // Internal helper to get all historical positions
    fn get_historical_positions_internal(
        &self,
        owner_pub_key: &[u8],
    ) -> Result<Vec<HistoricalPosition>> {
        match self.historical_positions.get(owner_pub_key)? {
            Some(data) => Ok(serde_json::from_slice(&data)?),
            None => Ok(Vec::new()),
        }
    }

    // Public method with pagination
    pub fn get_historical_positions(
        &self,
        owner_pub_key: &[u8],
        cursor: Option<usize>,
        page_size: usize,
    ) -> Result<PaginatedResponse<HistoricalPosition>> {
        let all_positions = self.get_historical_positions_internal(owner_pub_key)?;
        let start = cursor.unwrap_or(0);
        let end = std::cmp::min(start + page_size, all_positions.len());

        if start >= all_positions.len() {
            return Ok(PaginatedResponse {
                items: vec![],
                has_more: false,
                next_cursor: None,
            });
        }

        let items = all_positions[start..end].to_vec();
        let has_more = end < all_positions.len();
        let next_cursor = if has_more {
            Some(end.to_string())
        } else {
            None
        };

        Ok(PaginatedResponse {
            items,
            has_more,
            next_cursor,
        })
    }

    // --- Note Management ---

    pub fn add_unspent_note(&self, note: &UnspentNote) -> Result<()> {
        let receiver_hash_bytes = hex::decode(
            note.note
                .receiver_hash
                .strip_prefix("0x")
                .unwrap_or(&note.note.receiver_hash),
        )?;
        let mut notes = self.get_unspent_notes(&receiver_hash_bytes)?;
        notes.push(note.clone());
        self.unspent_notes
            .insert(receiver_hash_bytes, serde_json::to_vec(&notes)?)?;
        println!("Note added {}", format!("{}", note.note_id));
        Ok(())
    }

    pub fn remove_unspent_note(&self, note_id_to_remove: &[u8]) -> Result<()> {
        println!(
            "Removing Note {}",
            format!("0x{}", hex::encode(note_id_to_remove))
        );
        for item in self.unspent_notes.iter() {
            let (key, value) = item?;
            let mut notes: Vec<UnspentNote> = serde_json::from_slice(&value)?;
            let original_len = notes.len();
            notes.retain(|n| n.note_id != format!("0x{}", hex::encode(note_id_to_remove)));
            if notes.len() < original_len {
                self.unspent_notes
                    .insert(key, serde_json::to_vec(&notes)?)?;
                println!(
                    "Note retained {} now notes length {}",
                    format!("0x{}", hex::encode(note_id_to_remove)),
                    notes.len()
                );
                return Ok(());
            }
        }
        Ok(())
    }

    pub fn get_unspent_notes(&self, receiver_hash: &[u8]) -> Result<Vec<UnspentNote>> {
        match self.unspent_notes.get(receiver_hash)? {
            Some(data) => Ok(serde_json::from_slice(&data)?),
            None => Ok(Vec::new()),
        }
    }

    // pub fn set_user_metadata(&self, owner_pub_key: &[u8], encrypted_blob: Vec<u8>) -> Result<()> {
    //     self.user_metadata.insert(owner_pub_key, encrypted_blob)?;
    //     Ok(())
    // }

    // pub fn get_user_metadata(&self, owner_pub_key: &[u8]) -> Result<Option<Vec<u8>>> {
    //     Ok(self.user_metadata.get(owner_pub_key)?.map(|iv| iv.to_vec()))
    // }
}
