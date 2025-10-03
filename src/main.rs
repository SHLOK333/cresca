use anyhow::Result;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

mod aptos;
mod market_data;
mod risk;
mod trading;
mod utils;

use crate::{
    aptos::client::AptosClient,
    market_data::feed::MarketDataFeed,
    risk::manager::RiskManager,
    trading::{executor::Executor, strategy::MarketMakingStrategy},
    utils::config::Config,
};

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    info!("Starting the Aptos High-Frequency Trading Bot...");

    // Load configuration
    let config = Config::load()?;
    info!("Configuration loaded successfully");

    // Initialize Aptos client
    let aptos_client = AptosClient::new(config.aptos.clone()).await?;
    info!("Aptos client initialized");

    // Check account balance
    let balance = aptos_client.get_account_balance("0x1::aptos_coin::AptosCoin").await?;
    info!("Current APT balance: {}", balance);

    // Initialize components
    let market_data_feed = MarketDataFeed::new(config.market_data.clone()).await?;
    let mut strategy = MarketMakingStrategy::new(config.clone());
    let mut executor = Executor::new(aptos_client, config.trading.clone());
    executor.set_mock_mode(false); // 🔥 ENABLE REAL ON-CHAIN EXECUTION
    let mut risk_manager = RiskManager::new(config.risk.clone());

    info!("All components initialized, starting trading loop...");

    // Main trading loop
    let mut cycle_count = 0;
    loop {
        cycle_count += 1;
        info!("=== Trading Cycle #{} ===", cycle_count);
        
        match run_trading_cycle(
            &market_data_feed,
            &mut strategy,
            &mut executor,
            &mut risk_manager,
        ).await {
            Ok(executed) => {
                if executed {
                    info!("✅ Trade executed successfully in cycle #{}", cycle_count);
                } else {
                    info!("⏸️  No trade executed in cycle #{}", cycle_count);
                }
            },
            Err(e) => {
                error!("❌ Error in trading cycle #{}: {}", cycle_count, e);
                // Sleep longer on error to avoid rapid error loops
                sleep(Duration::from_secs(5)).await;
            }
        }

        sleep(Duration::from_millis(config.trading.tick_interval_ms)).await;
    }
}

async fn run_trading_cycle(
    market_data_feed: &MarketDataFeed,
    strategy: &mut MarketMakingStrategy,
    executor: &mut Executor,
    risk_manager: &mut RiskManager,
) -> Result<bool> {
    // Get latest market data
    let market_data = market_data_feed.get_latest_data().await?;
    
    // Update risk manager with current portfolio state
    risk_manager.update_portfolio().await?;
    
    // Check if we should continue trading (risk checks)
    if !risk_manager.can_trade() {
        warn!("⏸️  Risk manager preventing trading");
        return Ok(false);
    }

    // Generate trading signal
    if let Some(signal) = strategy.evaluate(&market_data).await? {
        info!("🎯 Generated trading signal: {} {} at ${} (strength: {})", 
               match signal.signal_type {
                   crate::aptos::types::SignalType::Buy => "BUY",
                   crate::aptos::types::SignalType::Sell => "SELL", 
                   crate::aptos::types::SignalType::Hold => "HOLD",
               },
               signal.quantity,
               signal.price,
               signal.strength);
        
        // Risk check the signal
        if risk_manager.validate_signal(&signal)? {
            info!("✅ Signal passed risk validation");
            
            // Execute the trade
            match executor.execute_signal(&signal).await {
                Ok(trade) => {
                    info!("🚀 TRADE EXECUTED! Hash: {}", trade.transaction_hash);
                    info!("   └─ {} {} {} at ${} (Fee: ${})", 
                          match trade.side {
                              crate::aptos::types::OrderSide::Buy => "BOUGHT",
                              crate::aptos::types::OrderSide::Sell => "SOLD",
                          },
                          trade.quantity, 
                          trade.symbol, 
                          trade.price,
                          trade.fee);
                    
                    risk_manager.record_trade(&trade).await?;
                    return Ok(true); // Trade was executed
                },
                Err(e) => {
                    error!("❌ Failed to execute trade: {}", e);
                }
            }
        } else {
            warn!("⚠️  Signal rejected by risk manager");
        }
    } else {
        info!("📊 No trading opportunity found");
    }

    Ok(false) // No trade executed
}