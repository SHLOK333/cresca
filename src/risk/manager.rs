use anyhow::Result;
use std::collections::HashMap;
use tracing::{info, warn};

use crate::aptos::types::{Trade, TradingSignal};
use crate::utils::config::RiskConfig;

pub struct RiskManager {
    config: RiskConfig,
    daily_pnl: rust_decimal::Decimal,
    current_positions: HashMap<String, rust_decimal::Decimal>,
    trade_count: u32,
}

impl RiskManager {
    pub fn new(config: RiskConfig) -> Self {
        Self {
            config,
            daily_pnl: rust_decimal::Decimal::ZERO,
            current_positions: HashMap::new(),
            trade_count: 0,
        }
    }

    pub async fn update_portfolio(&mut self) -> Result<()> {
        // Update portfolio state
        info!("Updating portfolio state");
        Ok(())
    }

    pub fn can_trade(&self) -> bool {
        // Check if daily loss limit exceeded
        if self.daily_pnl <= -self.config.max_daily_loss {
            warn!("Daily loss limit exceeded: {}", self.daily_pnl);
            return false;
        }

        true
    }

    pub fn validate_signal(&self, signal: &TradingSignal) -> Result<bool> {
        // Check position size limits
        let current_position = self.current_positions
            .get(&signal.symbol)
            .copied()
            .unwrap_or(rust_decimal::Decimal::ZERO);

        let new_position = match signal.signal_type {
            crate::aptos::types::SignalType::Buy => current_position + signal.quantity,
            crate::aptos::types::SignalType::Sell => current_position - signal.quantity,
            crate::aptos::types::SignalType::Hold => current_position,
        };

        if new_position.abs() > self.config.max_position_size {
            warn!("Position size limit exceeded for {}: {}", signal.symbol, new_position);
            return Ok(false);
        }

        Ok(true)
    }

    pub async fn record_trade(&mut self, trade: &Trade) -> Result<()> {
        // Update positions
        let current_position = self.current_positions
            .get(&trade.symbol)
            .copied()
            .unwrap_or(rust_decimal::Decimal::ZERO);

        let new_position = match trade.side {
            crate::aptos::types::OrderSide::Buy => current_position + trade.quantity,
            crate::aptos::types::OrderSide::Sell => current_position - trade.quantity,
        };

        self.current_positions.insert(trade.symbol.clone(), new_position);
        self.trade_count += 1;

        info!("Recorded trade: {} {} at {}", 
              trade.quantity, trade.symbol, trade.price);

        Ok(())
    }
}