use actix_web::{web, App, HttpServer, Responder, HttpResponse};
use serde::{Serialize, Deserialize};
use std::sync::{Arc, Mutex};

#[derive(Serialize, Clone)]
struct BotStatus {
    balance: f64,
    open_trades: u32,
    last_txn: String,
    running: bool,
    trade_log: Vec<Trade>,
}

#[derive(Serialize, Deserialize, Clone)]
struct Trade {
    coin: String,
    amount: f64,
    price: f64,
    link: String,
}

#[derive(Deserialize)]
struct TradeRequest {
    coin: String,
    amount: f64,
}

async fn get_status(data: web::Data<Arc<Mutex<BotStatus>>>) -> impl Responder {
    let status = data.lock().unwrap().clone();
    HttpResponse::Ok().json(status)
}

async fn start_bot(data: web::Data<Arc<Mutex<BotStatus>>>) -> impl Responder {
    let mut status = data.lock().unwrap();
    status.running = true;
    HttpResponse::Ok().body("Bot started")
}

async fn stop_bot(data: web::Data<Arc<Mutex<BotStatus>>>) -> impl Responder {
    let mut status = data.lock().unwrap();
    status.running = false;
    HttpResponse::Ok().body("Bot stopped")
}

async fn trade(
    data: web::Data<Arc<Mutex<BotStatus>>>,
    req: web::Json<TradeRequest>,
) -> impl Responder {
    let mut status = data.lock().unwrap();
    if !status.running {
        return HttpResponse::BadRequest().body("Bot not running");
    }
    let price = match req.coin.as_str() {
        "APT" => 7.20,
        "BTC" => 27000.0,
        "ETH" => 1600.0,
        _ => 1.0,
    };
    status.balance -= req.amount * price * 0.01;
    status.open_trades += 1;
    let txn_link = status.last_txn.clone();
    status.trade_log.push(Trade {
        coin: req.coin.clone(),
        amount: req.amount,
        price,
        link: txn_link,
    });
    HttpResponse::Ok().body("Trade executed")
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let status = Arc::new(Mutex::new(BotStatus {
        balance: 10000.0,
        open_trades: 3,
        last_txn: "https://explorer.aptoslabs.com/txn/0xe37acb93eea8132030e477738b3ba0a6d9c949ca73766fcb78597554d1729ab2?network=testnet".to_string(),
        running: false,
        trade_log: vec![
            Trade { coin: "APT".to_string(), amount: 100.0, price: 7.20, link: "https://explorer.aptoslabs.com/txn/0xe37acb93eea8132030e477738b3ba0a6d9c949ca73766fcb78597554d1729ab2?network=testnet".to_string() },
            Trade { coin: "BTC".to_string(), amount: 0.1, price: 27000.0, link: "#".to_string() },
            Trade { coin: "ETH".to_string(), amount: 2.0, price: 1600.0, link: "#".to_string() },
        ],
    }));

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(status.clone()))
            .route("/status", web::get().to(get_status))
            .route("/start", web::post().to(start_bot))
            .route("/stop", web::post().to(stop_bot))
            .route("/trade", web::post().to(trade))
    })
    .bind(("127.0.0.1", 8080))?
    .run()
    .await
}
