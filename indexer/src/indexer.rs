// src/indexer.rs - Aptos implementation  
use crate::{
    config::Config,
    database::Database,
    models::{Position, PositionStatus, UnspentNote},
};
use anyhow::{Result, anyhow};
use reqwest::Client;
use serde_json::Value;
use std::sync::Arc;
use tokio::time::{sleep, Duration};

const TRANSACTION_CHUNK_SIZE: u64 = 100;
const POLLING_INTERVAL_SECONDS: u64 = 5;
const RESTART_DELAY_SECONDS: u64 = 10;

// Aptos module addresses (0x2 from our Move.toml)
const NOX_MODULE_ADDRESS: &str = "0x0000000000000000000000000000000000000000000000000000000000000002";

pub async fn run_indexer(
    config: Arc<Config>,
    db: Arc<Database>,
    http_client: Arc<Client>,
) -> Result<()> {
    loop {
        if let Err(e) = indexer_logic(config.clone(), db.clone(), http_client.clone()).await {
            eprintln!(
                "[Indexer] Error encountered: {}. Restarting in {} seconds...",
                e, RESTART_DELAY_SECONDS
            );
            sleep(Duration::from_secs(RESTART_DELAY_SECONDS)).await;
        }
    }
}

async fn indexer_logic(
    config: Arc<Config>,
    db: Arc<Database>,
    http_client: Arc<Client>,
) -> Result<()> {
    println!("[Indexer] Starting Aptos indexer...");
    println!("[Indexer] Monitoring NOX modules at: {}", NOX_MODULE_ADDRESS);

    // Get starting version
    let ledger_info = get_ledger_info(&http_client, &config.rpc_url).await?;
    let mut from_version = ledger_info["ledger_version"]
        .as_str()
        .ok_or_else(|| anyhow!("Invalid ledger version"))?
        .parse::<u64>()?
        .saturating_sub(100);
    
    println!("[Indexer] Starting from version: {}", from_version);

    loop {
        let latest_ledger = match get_ledger_info(&http_client, &config.rpc_url).await {
            Ok(info) => info,
            Err(e) => {
                eprintln!("[Indexer] Failed to get ledger info: {}", e);
                sleep(Duration::from_secs(POLLING_INTERVAL_SECONDS)).await;
                continue;
            }
        };

        let latest_version = latest_ledger["ledger_version"]
            .as_str()
            .ok_or_else(|| anyhow!("Invalid ledger version"))?
            .parse::<u64>()?;
        
        if from_version >= latest_version {
            sleep(Duration::from_secs(POLLING_INTERVAL_SECONDS)).await;
            continue;
        }

        let to_version = (from_version + TRANSACTION_CHUNK_SIZE - 1).min(latest_version);

        match get_transactions(&http_client, &config.rpc_url, from_version, to_version).await {
            Ok(transactions) => {
                for transaction in transactions.as_array().unwrap_or(&vec![]) {
                    if let Err(e) = process_transaction(&db, transaction).await {
                        eprintln!("[Indexer] Error processing transaction: {}", e);
                    }
                }
                from_version = to_version + 1;
            }
            Err(e) => {
                eprintln!("[Indexer] Error fetching transactions: {}", e);
                sleep(Duration::from_secs(POLLING_INTERVAL_SECONDS)).await;
                continue;
            }
        }

        sleep(Duration::from_millis(500)).await;
    }
}

async fn get_ledger_info(client: &Client, rpc_url: &str) -> Result<Value> {
    let url = format!("{}/", rpc_url);
    let response = client.get(&url).send().await?;
    Ok(response.json().await?)
}

async fn get_transactions(client: &Client, rpc_url: &str, start: u64, end: u64) -> Result<Value> {
    let url = format!("{}/transactions?start={}&limit={}", rpc_url, start, end - start + 1);
    let response = client.get(&url).send().await?;
    Ok(response.json().await?)
}

async fn process_transaction(db: &Database, transaction: &Value) -> Result<()> {  
    let tx_type = transaction["type"].as_str().unwrap_or("");
    if tx_type != "user_transaction" {
        return Ok(());
    }

    let payload = &transaction["payload"];
    if let Some(function) = payload["function"].as_str() {
        if !function.starts_with(NOX_MODULE_ADDRESS) {
            return Ok(());
        }
    } else {
        return Ok(());
    }

    if let Some(events) = transaction["events"].as_array() {
        for event in events {
            if let Err(e) = process_event(db, event).await {
                eprintln!("[Indexer] Error processing event: {}", e);
            }
        }
    }

    Ok(())
}

async fn process_event(db: &Database, event: &Value) -> Result<()> {
    let event_type = event["type"].as_str().unwrap_or("");
    let event_data = &event["data"];

    match event_type {
        s if s.contains("token_pool::NoteCreated") => {
            handle_note_created(db, event_data).await
        }
        s if s.contains("token_pool::NoteClaimed") => {
            handle_note_claimed(db, event_data).await  
        }
        s if s.contains("privacy_proxy::PositionOpened") => {
            handle_position_opened(db, event_data).await
        }
        s if s.contains("clearing_house::PositionClosed") => {
            handle_position_closed(db, event_data).await
        }
        s if s.contains("clearing_house::PositionLiquidated") => {
            handle_position_liquidated(db, event_data).await
        }
        _ => Ok(())
    }
}

async fn handle_note_created(db: &Database, event_data: &Value) -> Result<()> {
    let note_nonce = event_data["note_nonce"].as_u64().unwrap_or(0);
    let receiver_hash = event_data["receiver_hash"].as_str().unwrap_or("");
    let amount = event_data["amount"].as_str().unwrap_or("0");

    let note_id = format!("0x{:016x}", note_nonce);
    
    let unspent_note = UnspentNote {
        note_id: note_id.clone(),
        note: crate::models::Note {
            note_nonce,
            receiver_hash: receiver_hash.to_string(),
            value: amount.to_string(),
        },
    };
    
    db.add_unspent_note(&unspent_note)?;
    Ok(())
}

async fn handle_note_claimed(db: &Database, event_data: &Value) -> Result<()> {
    let note_id = event_data["note_id"].as_str().unwrap_or("");
    let note_id_bytes = hex::decode(note_id.strip_prefix("0x").unwrap_or(note_id))?;
    db.remove_unspent_note(&note_id_bytes)?;
    Ok(())
}

async fn handle_position_opened(db: &Database, event_data: &Value) -> Result<()> {
    let position_id = event_data["position_id"].as_str().unwrap_or("");
    let is_long = event_data["is_long"].as_bool().unwrap_or(false);
    let entry_price = event_data["entry_price"].as_str().unwrap_or("0");
    let margin = event_data["margin"].as_str().unwrap_or("0");
    let size = event_data["size"].as_str().unwrap_or("0");
    let owner_hash = event_data["owner_hash"].as_str().unwrap_or("0");

    let position = Position {
        position_id: position_id.to_string(),
        is_long,
        entry_price: entry_price.to_string(),
        margin: margin.to_string(),
        size: size.to_string(),
    };
    
    let owner_key_bytes = hex::decode(owner_hash.strip_prefix("0x").unwrap_or(owner_hash))?;
    let mut owner_id = [0u8; 32];
    owner_id[..owner_key_bytes.len().min(32)].copy_from_slice(&owner_key_bytes[..owner_key_bytes.len().min(32)]);
    
    db.add_open_position(&owner_id, position)?;
    Ok(())
}

async fn handle_position_closed(db: &Database, event_data: &Value) -> Result<()> {
    let position_id = event_data["position_id"].as_str().unwrap_or("");
    let pnl = event_data["pnl"].as_str().unwrap_or("0");
    let user = event_data["user"].as_str().unwrap_or("unknown");

    let position_id_bytes = hex::decode(position_id.strip_prefix("0x").unwrap_or(position_id))?;
    db.move_to_historical(&position_id_bytes, PositionStatus::Closed, pnl.to_string(), user.to_string())?;
    Ok(())
}

async fn handle_position_liquidated(db: &Database, event_data: &Value) -> Result<()> {
    let position_id = event_data["position_id"].as_str().unwrap_or("");
    let user = event_data["user"].as_str().unwrap_or("unknown");

    let position_id_bytes = hex::decode(position_id.strip_prefix("0x").unwrap_or(position_id))?;
    db.move_to_historical(&position_id_bytes, PositionStatus::Liquidated, "Liquidated".to_string(), user.to_string())?;
    Ok(())
}
