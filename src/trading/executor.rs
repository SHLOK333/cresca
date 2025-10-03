use crate::aptos::client::AptosClient;
use crate::aptos::types::{Trade, TradingSignal};
use crate::utils::config::TradingConfig;
use anyhow::Result;
use tracing::{info, warn, error};
use rand;

pub struct Executor {
    client: AptosClient,
    config: TradingConfig,
    mock_mode: bool,
}

impl Executor {
    pub fn new(client: AptosClient, config: TradingConfig) -> Self {
        Executor { 
            client, 
            config,
            mock_mode: true, // Start in mock mode for safe testing
        }
    }

    pub fn set_mock_mode(&mut self, mock_mode: bool) {
        self.mock_mode = mock_mode;
        if mock_mode {
            warn!("⚠️  Trading executor set to MOCK MODE");
        } else {
            warn!("🔥 Trading executor set to LIVE MODE - Real transactions will be submitted!");
        }
    }

    pub async fn execute_signal(&mut self, signal: &TradingSignal) -> Result<Trade> {
        // Convert signal to trade execution
        match signal.signal_type {
            crate::aptos::types::SignalType::Buy => {
                self.execute_buy(signal).await
            },
            crate::aptos::types::SignalType::Sell => {
                self.execute_sell(signal).await
            },
            crate::aptos::types::SignalType::Hold => {
                // No action for hold signals
                Err(anyhow::anyhow!("Hold signal - no execution needed"))
            }
        }
    }

    async fn execute_buy(&self, signal: &TradingSignal) -> Result<Trade> {
        let hash = if self.mock_mode {
            info!("🧪 MOCK BUY: {} {} at ${}", signal.quantity, signal.symbol, signal.price);
            
            // Simulate network delay
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
            
            // Simulate occasional failures (5% chance)
            if rand::random::<f64>() < 0.05 {
                error!("🔥 Mock transaction failed");
                return Err(anyhow::anyhow!("Simulated network error"));
            }
            
            format!("0x{}", uuid::Uuid::new_v4().to_string().replace("-", ""))
        } else {
            info!("🔗 REAL BUY: Executing on-chain transaction...");
            self.client.swap_tokens(
                &self.config.quote_currency,
                &self.config.base_currency,
                signal.quantity.to_string().parse().unwrap_or(100),
                (signal.price * signal.quantity * rust_decimal::Decimal::from_f32_retain(0.98).unwrap()).to_string().parse().unwrap_or(90)
            ).await?
        };

        Ok(Trade {
            id: uuid::Uuid::new_v4().to_string(),
            order_id: uuid::Uuid::new_v4().to_string(),
            symbol: signal.symbol.clone(),
            side: crate::aptos::types::OrderSide::Buy,
            quantity: signal.quantity,
            price: signal.price,
            fee: signal.price * signal.quantity * rust_decimal::Decimal::from_f32_retain(0.003).unwrap(),
            timestamp: chrono::Utc::now(),
            transaction_hash: hash,
        })
    }

    async fn execute_sell(&self, signal: &TradingSignal) -> Result<Trade> {
        let hash = if self.mock_mode {
            info!("🧪 MOCK SELL: {} {} at ${}", signal.quantity, signal.symbol, signal.price);
            
            // Simulate network delay
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
            
            // Simulate occasional failures (5% chance)
            if rand::random::<f64>() < 0.05 {
                error!("🔥 Mock transaction failed");
                return Err(anyhow::anyhow!("Simulated network error"));
            }
            
            format!("0x{}", uuid::Uuid::new_v4().to_string().replace("-", ""))
        } else {
            info!("🔗 REAL SELL: Executing on-chain transaction...");
            self.client.swap_tokens(
                &self.config.base_currency,
                &self.config.quote_currency,
                signal.quantity.to_string().parse().unwrap_or(100),
                (signal.price * signal.quantity * rust_decimal::Decimal::from_f32_retain(0.98).unwrap()).to_string().parse().unwrap_or(90)
            ).await?
        };

        Ok(Trade {
            id: uuid::Uuid::new_v4().to_string(),
            order_id: uuid::Uuid::new_v4().to_string(),
            symbol: signal.symbol.clone(),
            side: crate::aptos::types::OrderSide::Sell,
            quantity: signal.quantity,
            price: signal.price,
            fee: signal.price * signal.quantity * rust_decimal::Decimal::from_f32_retain(0.003).unwrap(),
            timestamp: chrono::Utc::now(),
            transaction_hash: hash,
        })
    }
}