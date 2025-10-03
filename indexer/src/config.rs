use std::env;

#[derive(Clone, Debug)]
pub struct Config {
    pub rpc_url: String,
    pub nox_module_address: String, // Changed from privacy_proxy_address
    pub db_path: String,
    pub server_bind_address: String,
}

impl Config {
    pub fn from_env() -> Result<Self, anyhow::Error> {
        dotenv::dotenv().ok();
        Ok(Self {
            rpc_url: env::var("APTOS_RPC_URL")
                .unwrap_or_else(|_| "https://api.testnet.aptoslabs.com/v1".to_string()),
            nox_module_address: env::var("NOX_MODULE_ADDRESS")
                .unwrap_or_else(|_| "0x0000000000000000000000000000000000000000000000000000000000000002".to_string()),
            db_path: env::var("DB_PATH").unwrap_or_else(|_| "./db".to_string()),
            server_bind_address: env::var("SERVER_BIND_ADDRESS")
                .unwrap_or_else(|_| "0.0.0.0:3000".to_string()),
        })
    }
}
