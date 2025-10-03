use crate::aptos::types::MarketData;
use crate::aptos::types::{TradingSignal, SignalType};
use crate::utils::config::Config;
use rust_decimal::Decimal;
use rust_decimal::prelude::ToPrimitive;
use rand::Rng;
use anyhow::Result;

pub struct MarketMakingStrategy {
    config: Config,
    last_price: Option<Decimal>,
    price_history: Vec<Decimal>,
    signal_counter: u32,
}

impl MarketMakingStrategy {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            last_price: None,
            price_history: Vec::new(),
            signal_counter: 0,
        }
    }

    pub async fn evaluate(&mut self, market_data: &MarketData) -> Result<Option<TradingSignal>> {
        let current_price = market_data.price;
        self.price_history.push(current_price);
        
        // Keep only last 10 prices for moving average
        if self.price_history.len() > 10 {
            self.price_history.remove(0);
        }
        
        // Generate trading signals more frequently for testing
        self.signal_counter += 1;
        
        // Generate a signal every 5-10 cycles to test real transaction submission
        let mut rng = rand::thread_rng();
        let should_signal = self.signal_counter % rng.gen_range(5..=10) == 0;
        
        if should_signal && self.price_history.len() >= 3 {
            let signal_type = match rng.gen_range(0..3) {
                0 => SignalType::Buy,
                1 => SignalType::Sell,
                _ => SignalType::Hold,
            };
            
            // Skip Hold signals for now to focus on actual trades
            if signal_type == SignalType::Hold {
                return Ok(None);
            }
            
            let quantity = match signal_type {
                SignalType::Buy => Decimal::new(rng.gen_range(1..=5), 3), // 0.001 to 0.005 APT (tiny amounts for HFT)
                SignalType::Sell => Decimal::new(rng.gen_range(1..=5), 3), // 0.001 to 0.005 APT (tiny amounts for HFT)
                SignalType::Hold => Decimal::new(0, 0),
            };
            
            // Calculate signal strength based on price volatility
            let avg_price = self.price_history.iter().sum::<Decimal>() / Decimal::new(self.price_history.len() as i64, 0);
            let price_deviation = (current_price - avg_price).abs() / avg_price * Decimal::new(100, 0);
            let strength = price_deviation.min(Decimal::new(100, 0)); // Cap at 100%
            
            self.signal_counter = 0; // Reset counter
            
            let reason = match signal_type {
                SignalType::Buy => format!("Buy signal: price deviation {:.2}% from average", strength),
                SignalType::Sell => format!("Sell signal: price deviation {:.2}% from average", strength),
                SignalType::Hold => "Hold signal: market conditions stable".to_string(),
            };

            return Ok(Some(TradingSignal {
                symbol: market_data.symbol.clone(),
                signal_type,
                strength: strength.to_f64().unwrap_or(0.0),
                price: current_price,
                quantity,
                reason,
                timestamp: chrono::Utc::now(),
            }));
        }
        
        self.last_price = Some(current_price);
        Ok(None)
    }
}