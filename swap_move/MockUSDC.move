/// Mock USDC token for Aptos testnet - simplified version
/// This mimics the mUSDC token on Ethereum for better cross-chain UX
module cross_chain_swap::mock_usdc {
    use std::signer;
    use std::string::{Self, String};
    use std::error;
    
    use aptos_framework::coin::{Self, MintCapability, BurnCapability, FreezeCapability};

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_ALREADY_INITIALIZED: u64 = 3;
    const E_NOT_INITIALIZED: u64 = 4;

    /// Mock USDC coin type - represents the same mUSDC as on Ethereum
    struct MockUSDC has key {}

    /// Capabilities for minting and burning (stored under module account)
    struct Capabilities has key {
        mint_cap: MintCapability<MockUSDC>,
        burn_cap: BurnCapability<MockUSDC>,
        freeze_cap: FreezeCapability<MockUSDC>,
    }

    /// Configuration for the mock token
    struct TokenConfig has key {
        name: String,
        symbol: String,
        decimals: u8,
        total_supply: u128,
        admin: address,
    }

    /// Initialize the mock USDC coin
    /// This should be called during module deployment
    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        
        // Ensure we don't double-initialize
        assert!(!exists<Capabilities>(deployer_addr), error::already_exists(E_ALREADY_INITIALIZED));
        assert!(!exists<TokenConfig>(deployer_addr), error::already_exists(E_ALREADY_INITIALIZED));

        // Initialize the coin with same properties as Ethereum mUSDC
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<MockUSDC>(
            deployer,
            string::utf8(b"Mock USDC"), // Same name as Ethereum version
            string::utf8(b"mUSDC"),     // Same symbol as Ethereum version
            6, // 6 decimals like real USDC
            true, // monitor_supply
        );

        // Store capabilities under the module account
        move_to(deployer, Capabilities {
            mint_cap,
            burn_cap,
            freeze_cap,
        });

        // Store token configuration
        move_to(deployer, TokenConfig {
            name: string::utf8(b"Mock USDC"),
            symbol: string::utf8(b"mUSDC"),
            decimals: 6,
            total_supply: 0, // Will be updated as we mint
            admin: @0x5ac6a79cde1c926bf2021727adf74f7eedcca438be6a5be0d4629ef638ba9a98,
        });

        // Register the deployer to receive the token
        coin::register<MockUSDC>(deployer);
    }

    /// Mint mock USDC tokens to a specific address
    /// Only the admin can mint tokens
    public entry fun mint(
        admin: &signer,
        to: address,
        amount: u64
    ) acquires Capabilities, TokenConfig {
        let admin_addr = signer::address_of(admin);
        
        // Check if initialized
        assert!(exists<Capabilities>(admin_addr), error::not_found(E_NOT_INITIALIZED));
        assert!(exists<TokenConfig>(admin_addr), error::not_found(E_NOT_INITIALIZED));
        
        // Check authorization
        let config = borrow_global<TokenConfig>(admin_addr);
        assert!(admin_addr == config.admin, error::permission_denied(E_NOT_AUTHORIZED));
        
        // Get mint capability
        let caps = borrow_global<Capabilities>(admin_addr);
        let coins = coin::mint<MockUSDC>(amount, &caps.mint_cap);
        
        // Deposit the coins (recipient must be registered first)
        coin::deposit(to, coins);
        
        // Update total supply
        let config_mut = borrow_global_mut<TokenConfig>(admin_addr);
        config_mut.total_supply = config_mut.total_supply + (amount as u128);
    }

    /// Register an account to receive mock USDC
    public entry fun register(account: &signer) {
        if (!coin::is_account_registered<MockUSDC>(signer::address_of(account))) {
            coin::register<MockUSDC>(account);
        };
    }

    /// Transfer mock USDC tokens between accounts
    public entry fun transfer(
        from: &signer,
        to: address,
        amount: u64
    ) {
        let coins = coin::withdraw<MockUSDC>(from, amount);
        coin::deposit(to, coins);
    }

    /// Get balance of mock USDC for an account
    #[view]
    public fun balance(account: address): u64 {
        if (coin::is_account_registered<MockUSDC>(account)) {
            coin::balance<MockUSDC>(account)
        } else {
            0
        }
    }

    /// Get token information
    #[view]
    public fun get_token_info(): (String, String, u8) acquires TokenConfig {
        let module_addr = @cross_chain_swap;
        if (exists<TokenConfig>(module_addr)) {
            let config = borrow_global<TokenConfig>(module_addr);
            (config.name, config.symbol, config.decimals)
        } else {
            (string::utf8(b"Mock USDC"), string::utf8(b"mUSDC"), 6)
        }
    }

    /// Get total supply
    #[view]
    public fun total_supply(): u128 acquires TokenConfig {
        let module_addr = @cross_chain_swap;
        if (exists<TokenConfig>(module_addr)) {
            let config = borrow_global<TokenConfig>(module_addr);
            config.total_supply
        } else {
            0
        }
    }

    /// Check if account is registered for this token
    public fun is_registered(account: address): bool {
        coin::is_account_registered<MockUSDC>(account)
    }

    #[test_only]
    use aptos_framework::account;

    #[test(admin = @cross_chain_swap)]
    fun test_init_and_mint(admin: signer) acquires Capabilities, TokenConfig {
        // Create account for testing
        account::create_account_for_test(signer::address_of(&admin));
        
        // Initialize the token
        init_module(&admin);
        
        // Create test user
        let user_addr = @0x123;
        account::create_account_for_test(user_addr);
        
        // Register user first
        let user = account::create_signer_for_test(user_addr);
        register(&user);
        
        // Mint some tokens
        mint(&admin, user_addr, 1000000); // 1 USDC (6 decimals)
        
        // Check balance
        assert!(balance(user_addr) == 1000000, 0);
        
        // Check total supply
        assert!(total_supply() == 1000000, 1);
    }
}