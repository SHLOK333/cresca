use anyhow::Result;
use reqwest::Client;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{error, info, warn};

use crate::aptos::types::{MarketData, OrderBook, PriceLevel};
use crate::utils::config::MarketDataConfig;

pub struct MarketDataFeed {
    config: MarketDataConfig,
    http_client: Client,
    latest_data: Arc<RwLock<Option<MarketData>>>,
}

impl MarketDataFeed {
    pub async fn new(config: MarketDataConfig) -> Result<Self> {
        let http_client = Client::new();
        let latest_data = Arc::new(RwLock::new(None));
        
        Ok(Self {
            config,
            http_client,
            latest_data,
        })
    }

    pub async fn fetch_data(&self) -> Result<MarketData> {
        // Mock market data for now
        // In a real implementation, this would call APIs from DEXs like:
        // - Hippo Aggregator API
        // - PancakeSwap on Aptos
        // - Liquidswap
        // - Other Aptos DEXs
        
        info!("Fetching market data from sources: {:?}", self.config.sources);
        
        let mock_data = MarketData {
            symbol: "TUSDC/APT".to_string(),
            price: rust_decimal::Decimal::from_f32_retain(8.5).unwrap(),
            bid_price: rust_decimal::Decimal::from_f32_retain(8.49).unwrap(),
            ask_price: rust_decimal::Decimal::from_f32_retain(8.51).unwrap(),
            volume_24h: rust_decimal::Decimal::from(1000000),
            price_change_24h: rust_decimal::Decimal::from_f32_retain(0.02).unwrap(),
            timestamp: chrono::Utc::now(),
            order_book: OrderBook {
                bids: vec![
                    PriceLevel { price: rust_decimal::Decimal::from_f32_retain(8.49).unwrap(), quantity: rust_decimal::Decimal::from(100) },
                    PriceLevel { price: rust_decimal::Decimal::from_f32_retain(8.48).unwrap(), quantity: rust_decimal::Decimal::from(200) },
                ],
                asks: vec![
                    PriceLevel { price: rust_decimal::Decimal::from_f32_retain(8.51).unwrap(), quantity: rust_decimal::Decimal::from(150) },
                    PriceLevel { price: rust_decimal::Decimal::from_f32_retain(8.52).unwrap(), quantity: rust_decimal::Decimal::from(300) },
                ],
                timestamp: chrono::Utc::now(),
            },
        };
        
        // Update cached data
        {
            let mut data = self.latest_data.write().await;
            *data = Some(mock_data.clone());
        }
        
        Ok(mock_data)
    }

    pub async fn get_latest_data(&self) -> Result<MarketData> {
        // Try to get cached data first
        {
            let data = self.latest_data.read().await;
            if let Some(ref market_data) = *data {
                // Check if data is recent enough (within update interval)
                let age = chrono::Utc::now() - market_data.timestamp;
                if age.num_milliseconds() < (self.config.update_interval_ms as i64) * 2 {
                    return Ok(market_data.clone());
                }
            }
        }
        
        // Fetch fresh data if cached data is too old or doesn't exist
        self.fetch_data().await
    }

    pub async fn start_background_updates(&self) {
        let feed = self.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(
                tokio::time::Duration::from_millis(feed.config.update_interval_ms)
            );
            
            loop {
                interval.tick().await;
                if let Err(e) = feed.fetch_data().await {
                    error!("Failed to fetch market data: {}", e);
                }
            }
        });
    }
}

impl Clone for MarketDataFeed {
    fn clone(&self) -> Self {
        Self {
            config: self.config.clone(),
            http_client: self.http_client.clone(),
            latest_data: Arc::clone(&self.latest_data),
        }
    }
}