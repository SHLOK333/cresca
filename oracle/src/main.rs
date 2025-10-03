use ethers::{
    prelude::*,
    providers::{Http, Provider},
    signers::{LocalWallet, Signer},
    types::U256,
};

use anyhow::Result;
use serde::Deserialize;
use std::{env, str::FromStr, sync::Arc, time::Duration};

// Generate the an `Oracle` struct with all the type-safe bindings from the ABI.
abigen!(Oracle, "abi/Oracle.json");

// Pyth price update response structures
#[derive(Debug, Deserialize)]
struct PythPriceResponse {
    binary: PythBinary,
    parsed: Vec<PythParsedPrice>,
}

#[derive(Debug, Deserialize)]
struct PythBinary {
    encoding: String,
    data: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct PythParsedPrice {
    id: String,
    price: PythPrice,
    ema_price: PythPrice,
    metadata: PythMetadata,
}

#[derive(Debug, Deserialize)]
struct PythPrice {
    price: String,
    conf: String,
    expo: i32,
    publish_time: u64,
}

#[derive(Debug, Deserialize)]
struct PythMetadata {
    slot: u64,
    proof_available_time: u64,
    prev_publish_time: u64,
}

async fn fetch_btc_price_from_pyth(client: &reqwest::Client) -> Result<(f64, Vec<u8>)> {
    // BTC/USD price feed ID from Pyth Network
    let btc_price_id = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";

    let url = format!(
        "https://hermes.pyth.network/v2/updates/price/latest?ids[]={}",
        btc_price_id
    );

    let response = client
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json::<PythPriceResponse>()
        .await?;

    // Extract the price data
    if let Some(parsed_price) = response.parsed.first() {
        // Convert the price using the exponent
        let price_raw: i64 = parsed_price.price.price.parse()?;
        let expo = parsed_price.price.expo;
        let price_f64 = price_raw as f64 * 10f64.powi(expo);

        // Get the binary price update data for the smart contract
        let price_update_data = if let Some(hex_data) = response.binary.data.first() {
            hex::decode(hex_data.trim_start_matches("0x"))?
        } else {
            return Err(anyhow::anyhow!("No binary price update data found"));
        };

        println!(
            "Fetched price from Pyth: ${:.2} (confidence: ${:.2})",
            price_f64,
            parsed_price.price.conf.parse::<i64>()? as f64 * 10f64.powi(expo)
        );

        Ok((price_f64, price_update_data))
    } else {
        Err(anyhow::anyhow!("No price data found in Pyth response"))
    }
}

/// Alternative: Fetch using streaming endpoint for real-time updates
async fn setup_pyth_streaming(client: &reqwest::Client) -> Result<()> {
    let btc_price_id = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";

    let url = format!(
        "https://hermes.pyth.network/v2/updates/price/stream?ids[]={}",
        btc_price_id
    );

    println!("Setting up Pyth streaming from: {}", url);

    Ok(())
}

/// Converts a floating-point price into a U256 integer with 18 decimals.
fn to_u256_price(price: f64) -> U256 {
    let scaled_price = price * 1e18;
    U256::from(scaled_price as u128)
}

#[tokio::main]
async fn main() -> Result<()> {
    // Load configuration from the .env file
    dotenv::dotenv().ok();
    let rpc_url = env::var("RPC_URL").expect("RPC_URL must be set");
    let private_key = env::var("PRIVATE_KEY").expect("PRIVATE_KEY must be set");
    let contract_address =
        env::var("ORACLE_CONTRACT_ADDRESS").expect("ORACLE_CONTRACT_ADDRESS must be set");
    let price_threshold: f64 = env::var("PRICE_CHANGE_THRESHOLD")
        .expect("PRICE_CHANGE_THRESHOLD must be set")
        .parse()?;

    // Set up the Ethereum provider and client
    let provider = Provider::<Http>::try_from(&rpc_url)?;
    let chain_id = provider.get_chainid().await?.as_u64();

    // Create a signer instance from our private key
    let wallet = LocalWallet::from_str(&private_key)?.with_chain_id(chain_id);
    let client = Arc::new(SignerMiddleware::new(provider, wallet));

    // Create a type-safe instance of our Oracle contract
    let oracle_address: Address = contract_address.parse()?;
    let oracle_contract = Oracle::new(oracle_address, Arc::clone(&client));

    println!("🔮 Pyth Oracle Bot Started...");
    println!("-> Oracle Contract: {}", contract_address);
    println!("-> Updater Account: {:#x}", client.address());
    println!("-> Price Update Threshold: {}%", price_threshold * 100.0);
    println!("-> Using Pyth Network for BTC/USD price feeds");

    let mut last_sent_price: Option<U256> = None;
    let http_client = reqwest::Client::new();

    // Optional: Set up streaming (commented out for now)
    // setup_pyth_streaming(&http_client).await?;

    // Main application loop
    loop {
        println!("\n--- New Tick (Pyth Oracle) ---");

        // 1. Fetch Price from Pyth Network
        let (current_price_f64, price_update_data) =
            match fetch_btc_price_from_pyth(&http_client).await {
                Ok((price, data)) => (price, data),
                Err(e) => {
                    eprintln!("[ERROR] Failed to fetch price from Pyth: {}", e);
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    continue;
                }
            };

        let new_price_u256 = to_u256_price(current_price_f64);

        // 2. Caching and Threshold Logic
        if let Some(last_price) = last_sent_price {
            let last_f64 = last_price.as_u128() as f64 / 1e18;
            let change = ((current_price_f64 - last_f64) / last_f64).abs();

            if change < price_threshold {
                println!(
                    "Price change ({:.4}%) is within the threshold. No update needed.",
                    change * 100.0
                );
                tokio::time::sleep(Duration::from_secs(20)).await;
                continue;
            }
            println!(
                "Price change of {:.4}% detected. Submitting update...",
                change * 100.0
            );
        } else {
            println!("No last price cached. Submitting first price update...");
        }

        // 3. Submit price update to smart contract
        // Note: You may need to update your Oracle contract to accept Pyth price update data
        println!("Submitting Pyth price update to contract...");
        println!("Price: ${:.2}", current_price_f64);
        println!("Update data size: {} bytes", price_update_data.len());

        // Basic price update (modify based on your contract's interface)
        let call = oracle_contract.set_price(new_price_u256);

        // If your contract supports Pyth price updates directly, you might do:
        // let call = oracle_contract.update_price_feeds(price_update_data.into());

        match call.send().await {
            Ok(pending_tx) => {
                println!("Transaction sent. Waiting for confirmation...");
                match pending_tx.await {
                    Ok(Some(receipt)) => {
                        println!(
                            "✅ Pyth price update confirmed! Hash: {:#x}",
                            receipt.transaction_hash
                        );
                        last_sent_price = Some(new_price_u256);
                    }
                    Ok(None) => {
                        eprintln!("[ERROR] Transaction dropped from mempool.");
                    }
                    Err(e) => {
                        eprintln!("[ERROR] Failed to confirm transaction: {}", e);
                    }
                }
            }
            Err(e) => {
                eprintln!("[ERROR] Failed to send transaction: {}", e);
            }
        }

        // 4. Wait for the next cycle (Pyth updates frequently, so we can check more often)
        tokio::time::sleep(Duration::from_secs(15)).await;
    }
}
