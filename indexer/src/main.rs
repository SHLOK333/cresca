mod api;
mod config;
mod database;
mod indexer;
mod models;

use anyhow::Result;
use config::Config;
use database::Database;
use reqwest::Client;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    // 1. Load configuration
    let config = Arc::new(Config::from_env()?);
    println!("✅ Configuration loaded.");

    // 2. Initialize the database
    let db = Arc::new(Database::new(&config.db_path)?);
    println!("✅ Database connected at: {}", &config.db_path);

    // 3. Initialize HTTP client for Aptos REST API
    let http_client = Arc::new(Client::new());
    println!("✅ HTTP client created for Aptos REST API.");

    // Test connection by getting ledger info
    println!("config.rpc_url {}", config.rpc_url);
    let test_url = format!("{}/", config.rpc_url);
    let _ledger_info = match http_client.get(&test_url).send().await {
        Ok(response) => {
            if response.status().is_success() {
                println!("✅ Successfully connected to Aptos node");
                response.json::<serde_json::Value>().await.ok()
            } else {
                eprintln!("[FATAL INDEXER ERROR] Failed to connect to Aptos node: {}", response.status());
                return Err(anyhow::anyhow!("Connection failed"));
            }
        },
        Err(e) => {
            eprintln!("[FATAL INDEXER ERROR] Failed to connect to Aptos node: {}", e);
            return Err(e.into());
        }
    };

    // 4. Start the two main services concurrently
    println!("🚀 Starting API Server and Blockchain Indexer...");

    let api_handle = tokio::spawn(api::run_api_server(Arc::clone(&config), Arc::clone(&db)));
    let indexer_handle = tokio::spawn(indexer::run_indexer(
        Arc::clone(&config),
        Arc::clone(&db),
        Arc::clone(&http_client),
    ));

    // Keep the application running and handle exits gracefully
    tokio::select! {
        result = api_handle => {
            eprintln!("[FATAL] API server has exited.");
            result??;
        }
        result = indexer_handle => {
            eprintln!("[FATAL] Blockchain indexer has exited.");
            result??;
        }
    };

    Ok(())
}
