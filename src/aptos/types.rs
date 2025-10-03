use anyhow::Result;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenInfo {
    pub symbol: String,
    pub name: String,
    pub decimals: u8,
    pub coin_type: String,
    pub address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketData {
    pub symbol: String,
    pub price: Decimal,
    pub bid_price: Decimal,
    pub ask_price: Decimal,
    pub volume_24h: Decimal,
    pub price_change_24h: Decimal,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub order_book: OrderBook,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderBook {
    pub bids: Vec<PriceLevel>,
    pub asks: Vec<PriceLevel>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceLevel {
    pub price: Decimal,
    pub quantity: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum OrderSide {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum OrderType {
    Market,
    Limit,
    StopLoss,
    TakeProfit,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: String,
    pub symbol: String,
    pub side: OrderSide,
    pub order_type: OrderType,
    pub quantity: Decimal,
    pub price: Option<Decimal>,
    pub stop_price: Option<Decimal>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub status: OrderStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum OrderStatus {
    Pending,
    PartiallyFilled,
    Filled,
    Cancelled,
    Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trade {
    pub id: String,
    pub order_id: String,
    pub symbol: String,
    pub side: OrderSide,
    pub quantity: Decimal,
    pub price: Decimal,
    pub fee: Decimal,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub transaction_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Portfolio {
    pub balances: HashMap<String, Decimal>,
    pub total_value_usd: Decimal,
    pub pnl_24h: Decimal,
    pub pnl_total: Decimal,
    pub last_updated: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradingSignal {
    pub symbol: String,
    pub signal_type: SignalType,
    pub strength: f64, // 0.0 to 1.0
    pub price: Decimal,
    pub quantity: Decimal,
    pub reason: String,
    pub timestamp: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum SignalType {
    Buy,
    Sell,
    Hold,
}

impl MarketData {
    pub fn spread(&self) -> Decimal {
        self.ask_price - self.bid_price
    }

    pub fn mid_price(&self) -> Decimal {
        (self.bid_price + self.ask_price) / Decimal::from(2)
    }
}

impl OrderBook {
    pub fn best_bid(&self) -> Option<&PriceLevel> {
        self.bids.first()
    }

    pub fn best_ask(&self) -> Option<&PriceLevel> {
        self.asks.first()
    }

    pub fn spread(&self) -> Option<Decimal> {
        match (self.best_bid(), self.best_ask()) {
            (Some(bid), Some(ask)) => Some(ask.price - bid.price),
            _ => None,
        }
    }
}