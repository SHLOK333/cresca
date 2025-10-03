use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub aptos: AptosConfig,
    pub trading: TradingConfig,
    pub market_data: MarketDataConfig,
    pub risk: RiskConfig,
    pub logging: LoggingConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AptosConfig {
    pub node_url: String,
    pub private_key: String,
    pub account_address: String,
    pub chain_id: u8,
    pub gas_price: u64,
    pub max_gas_amount: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradingConfig {
    pub base_currency: String,
    pub quote_currency: String,
    pub min_order_size: rust_decimal::Decimal,
    pub max_order_size: rust_decimal::Decimal,
    pub tick_interval_ms: u64,
    pub strategy_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketDataConfig {
    pub sources: Vec<String>,
    pub websocket_url: Option<String>,
    pub rest_api_url: String,
    pub update_interval_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RiskConfig {
    pub max_position_size: rust_decimal::Decimal,
    pub max_daily_loss: rust_decimal::Decimal,
    pub stop_loss_threshold: rust_decimal::Decimal,
    pub take_profit_threshold: rust_decimal::Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoggingConfig {
    pub level: String,
    pub file_path: Option<String>,
}

impl Config {
    pub fn load() -> Result<Self> {
        dotenv::dotenv().ok();
        
        // Try to load from config file first
        if let Ok(config_str) = fs::read_to_string("config.toml") {
            return Ok(toml::from_str(&config_str)?);
        }
        
        // Fallback to environment variables
        Ok(Config {
            aptos: AptosConfig {
                node_url: std::env::var("APTOS_NODE_URL")
                    .unwrap_or_else(|_| "https://fullnode.testnet.aptoslabs.com/v1".to_string()),
                private_key: std::env::var("APTOS_PRIVATE_KEY")
                    .expect("APTOS_PRIVATE_KEY must be set"),
                account_address: std::env::var("APTOS_ACCOUNT_ADDRESS")
                    .expect("APTOS_ACCOUNT_ADDRESS must be set"),
                chain_id: std::env::var("APTOS_CHAIN_ID")
                    .unwrap_or_else(|_| "2".to_string())
                    .parse()
                    .unwrap_or(2),
                gas_price: std::env::var("APTOS_GAS_PRICE")
                    .unwrap_or_else(|_| "100".to_string())
                    .parse()
                    .unwrap_or(100),
                max_gas_amount: std::env::var("APTOS_MAX_GAS_AMOUNT")
                    .unwrap_or_else(|_| "10000".to_string())
                    .parse()
                    .unwrap_or(10000),
            },
            trading: TradingConfig {
                base_currency: std::env::var("BASE_CURRENCY")
                    .unwrap_or_else(|_| "TUSDC".to_string()),
                quote_currency: std::env::var("QUOTE_CURRENCY")
                    .unwrap_or_else(|_| "APT".to_string()),
                min_order_size: std::env::var("MIN_ORDER_SIZE")
                    .unwrap_or_else(|_| "1.0".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from(1)),
                max_order_size: std::env::var("MAX_ORDER_SIZE")
                    .unwrap_or_else(|_| "1000.0".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from(1000)),
                tick_interval_ms: std::env::var("TICK_INTERVAL_MS")
                    .unwrap_or_else(|_| "100".to_string())
                    .parse()
                    .unwrap_or(100),
                strategy_type: std::env::var("STRATEGY_TYPE")
                    .unwrap_or_else(|_| "market_making".to_string()),
            },
            market_data: MarketDataConfig {
                sources: vec!["aptos_dex".to_string()],
                websocket_url: std::env::var("MARKET_DATA_WS_URL").ok(),
                rest_api_url: std::env::var("MARKET_DATA_REST_URL")
                    .unwrap_or_else(|_| "https://api.example.com".to_string()),
                update_interval_ms: std::env::var("MARKET_DATA_INTERVAL_MS")
                    .unwrap_or_else(|_| "50".to_string())
                    .parse()
                    .unwrap_or(50),
            },
            risk: RiskConfig {
                max_position_size: std::env::var("MAX_POSITION_SIZE")
                    .unwrap_or_else(|_| "10000.0".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from(10000)),
                max_daily_loss: std::env::var("MAX_DAILY_LOSS")
                    .unwrap_or_else(|_| "1000.0".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from(1000)),
                stop_loss_threshold: std::env::var("STOP_LOSS_THRESHOLD")
                    .unwrap_or_else(|_| "0.02".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from_f32_retain(0.02).unwrap()),
                take_profit_threshold: std::env::var("TAKE_PROFIT_THRESHOLD")
                    .unwrap_or_else(|_| "0.01".to_string())
                    .parse()
                    .unwrap_or_else(|_| rust_decimal::Decimal::from_f32_retain(0.01).unwrap()),
            },
            logging: LoggingConfig {
                level: std::env::var("LOG_LEVEL")
                    .unwrap_or_else(|_| "info".to_string()),
                file_path: std::env::var("LOG_FILE_PATH").ok(),
            },
        })
    }
}