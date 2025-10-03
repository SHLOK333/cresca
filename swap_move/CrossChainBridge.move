/// Cross-Chain Bridge with Liquidity Pools
/// Enables single-sided deposits with automatic releases from reserves
module cross_chain_swap::cross_chain_bridge {
    use std::signer;
    use std::vector;
    use std::error;
    use std::option::{Self, Option};
    use std::timestamp;
    use std::event;
    use std::hash::sha3_256;
    use std::string::{Self, String};

    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use cross_chain_swap::mock_usdc::MockUSDC;

    // Error codes
    const E_NOT_OWNER: u64 = 1;
    const E_REQUEST_EXISTS: u64 = 2;
    const E_REQUEST_NOT_EXISTS: u64 = 3;
    const E_INSUFFICIENT_RESERVES: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_BRIDGE_PAUSED: u64 = 6;
    const E_REQUEST_EXPIRED: u64 = 7;
    const E_REQUEST_PROCESSED: u64 = 8;
    const E_NOT_RELAYER: u64 = 9;
    const E_INVALID_CHAIN: u64 = 10;

    // Constants
    const MIN_BRIDGE_AMOUNT: u64 = 1000; // 0.001 mUSDC minimum
    const MAX_BRIDGE_AMOUNT: u64 = 1000000000000; // 1M mUSDC maximum
    const REQUEST_EXPIRY: u64 = 86400; // 24 hours
    const BRIDGE_FEE: u64 = 10; // 0.1% (10/10000)
    const FEE_DENOMINATOR: u64 = 10000;

    // Chain identifiers
    const CHAIN_ETHEREUM: vector<u8> = b"ethereum";
    const CHAIN_APTOS: vector<u8> = b"aptos";

    struct BridgeRequest has store, drop {
        request_id: vector<u8>,
        user_address: address,
        destination_chain: vector<u8>,
        destination_address: vector<u8>, // Can be ETH address or Aptos address
        amount: u64,
        coin_type: u8, // 1 = APT, 2 = MockUSDC
        timestamp: u64,
        processed: bool,
        expired: bool,
    }

    struct BridgePool has key {
        // Liquidity reserves for different tokens
        apt_reserves: u64,
        musdc_reserves: u64,
        
        // Bridge management
        requests: vector<BridgeRequest>,
        owner: address,
        relayers: vector<address>,
        paused: bool,
        
        // Resource account for holding reserves
        signer_cap: account::SignerCapability,
        
        // Statistics
        total_bridged_in: u64,
        total_bridged_out: u64,
        fee_collected: u64,
    }

    #[event]
    struct BridgeRequestCreated has drop, store {
        request_id: vector<u8>,
        user_address: address,
        destination_chain: vector<u8>,
        destination_address: vector<u8>,
        amount: u64,
        coin_type: u8,
        timestamp: u64,
    }

    #[event]
    struct BridgeRequestProcessed has drop, store {
        request_id: vector<u8>,
        user_address: address,
        amount: u64,
        coin_type: u8,
        relayer: address,
        timestamp: u64,
    }

    #[event]
    struct ReservesAdded has drop, store {
        coin_type: u8,
        amount: u64,
        new_balance: u64,
        timestamp: u64,
    }

    // Initialize the bridge with resource account
    fun init_module(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        
        // Create resource account for holding reserves
        let (resource_signer, signer_cap) = account::create_resource_account(owner, b"bridge_reserves");
        
        let bridge_pool = BridgePool {
            apt_reserves: 0,
            musdc_reserves: 0,
            requests: vector::empty<BridgeRequest>(),
            owner: owner_addr,
            relayers: vector::empty<address>(),
            paused: false,
            signer_cap,
            total_bridged_in: 0,
            total_bridged_out: 0,
            fee_collected: 0,
        };
        
        // Add owner as first relayer
        vector::push_back(&mut bridge_pool.relayers, owner_addr);
        
        move_to(&resource_signer, bridge_pool);
    }

    // Bridge APT to Ethereum
    public entry fun bridge_apt_to_ethereum(
        user: &signer,
        amount: u64,
        eth_address: vector<u8>, // Ethereum address as bytes
    ) acquires BridgePool {
        bridge_to_chain<AptosCoin>(user, amount, CHAIN_ETHEREUM, eth_address, 1);
    }

    // Bridge mUSDC to Ethereum  
    public entry fun bridge_musdc_to_ethereum(
        user: &signer,
        amount: u64,
        eth_address: vector<u8>, // Ethereum address as bytes
    ) acquires BridgePool {
        bridge_to_chain<MockUSDC>(user, amount, CHAIN_ETHEREUM, eth_address, 2);
    }

    // Process bridge request from Ethereum (called by relayer)
    public entry fun process_ethereum_to_aptos_apt(
        relayer: &signer,
        request_id: vector<u8>,
        user_address: address,
        amount: u64,
    ) acquires BridgePool {
        process_bridge_request<AptosCoin>(relayer, request_id, user_address, amount, 1);
    }

    // Process bridge request from Ethereum for mUSDC (called by relayer)
    public entry fun process_ethereum_to_aptos_musdc(
        relayer: &signer,
        request_id: vector<u8>,
        user_address: address,
        amount: u64,
    ) acquires BridgePool {
        process_bridge_request<MockUSDC>(relayer, request_id, user_address, amount, 2);
    }

    // Internal bridge function
    fun bridge_to_chain<CoinType>(
        user: &signer,
        amount: u64,
        destination_chain: vector<u8>,
        destination_address: vector<u8>,
        coin_type: u8,
    ) acquires BridgePool {
        let user_addr = signer::address_of(user);
        let now = timestamp::now_seconds();
        
        // Validate inputs
        assert!(!is_bridge_paused(), error::permission_denied(E_BRIDGE_PAUSED));
        assert!(amount >= MIN_BRIDGE_AMOUNT && amount <= MAX_BRIDGE_AMOUNT, 
                error::invalid_argument(E_INVALID_AMOUNT));
        assert!(vector::length(&destination_address) > 0, 
                error::invalid_argument(E_INVALID_AMOUNT));

        // Check user balance
        let balance = coin::balance<CoinType>(user_addr);
        assert!(balance >= amount, error::invalid_state(E_INSUFFICIENT_RESERVES));

        // Generate unique request ID
        let request_id = generate_request_id(user_addr, destination_chain, amount, now);
        
        // Calculate fee and net amount
        let fee_amount = (amount * BRIDGE_FEE) / FEE_DENOMINATOR;
        let net_amount = amount - fee_amount;

        // Transfer tokens from user to bridge
        let payment = coin::withdraw<CoinType>(user, amount);
        let resource_address = get_resource_address();
        coin::deposit(resource_address, payment);

        // Update reserves and statistics
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);
        if (coin_type == 1) { // APT
            bridge_pool.apt_reserves = bridge_pool.apt_reserves + net_amount;
        } else { // MockUSDC
            bridge_pool.musdc_reserves = bridge_pool.musdc_reserves + net_amount;
        };
        bridge_pool.total_bridged_out = bridge_pool.total_bridged_out + net_amount;
        bridge_pool.fee_collected = bridge_pool.fee_collected + fee_amount;

        // Create bridge request
        let bridge_request = BridgeRequest {
            request_id,
            user_address: user_addr,
            destination_chain,
            destination_address,
            amount: net_amount,
            coin_type,
            timestamp: now,
            processed: false,
            expired: false,
        };

        vector::push_back(&mut bridge_pool.requests, bridge_request);

        // Emit event for relayers to process
        event::emit(BridgeRequestCreated {
            request_id,
            user_address: user_addr,
            destination_chain,
            destination_address,
            amount: net_amount,
            coin_type,
            timestamp: now,
        });
    }

    // Internal process bridge request
    fun process_bridge_request<CoinType>(
        relayer: &signer,
        request_id: vector<u8>,
        user_address: address,
        amount: u64,
        coin_type: u8,
    ) acquires BridgePool {
        let relayer_addr = signer::address_of(relayer);
        let now = timestamp::now_seconds();
        
        assert!(!is_bridge_paused(), error::permission_denied(E_BRIDGE_PAUSED));
        assert!(is_relayer(relayer_addr), error::permission_denied(E_NOT_RELAYER));

        let resource_address = get_resource_address();
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);

        // Check reserves
        let available_reserves = if (coin_type == 1) {
            bridge_pool.apt_reserves
        } else {
            bridge_pool.musdc_reserves
        };
        assert!(available_reserves >= amount, error::invalid_state(E_INSUFFICIENT_RESERVES));

        // Transfer tokens from bridge reserves to user
        let resource_signer = account::create_signer_with_capability(&bridge_pool.signer_cap);
        let coins = coin::withdraw<CoinType>(&resource_signer, amount);
        coin::deposit(user_address, coins);

        // Update reserves and statistics
        if (coin_type == 1) { // APT
            bridge_pool.apt_reserves = bridge_pool.apt_reserves - amount;
        } else { // MockUSDC
            bridge_pool.musdc_reserves = bridge_pool.musdc_reserves - amount;
        };
        bridge_pool.total_bridged_in = bridge_pool.total_bridged_in + amount;

        // Emit event
        event::emit(BridgeRequestProcessed {
            request_id,
            user_address,
            amount,
            coin_type,
            relayer: relayer_addr,
            timestamp: now,
        });
    }

    // Admin function to add reserves
    public entry fun add_apt_reserves(owner: &signer, amount: u64) acquires BridgePool {
        add_reserves<AptosCoin>(owner, amount, 1);
    }

    public entry fun add_musdc_reserves(owner: &signer, amount: u64) acquires BridgePool {
        add_reserves<MockUSDC>(owner, amount, 2);
    }

    fun add_reserves<CoinType>(owner: &signer, amount: u64, coin_type: u8) acquires BridgePool {
        let owner_addr = signer::address_of(owner);
        assert_owner(owner_addr);

        // Transfer tokens from owner to bridge reserves
        let payment = coin::withdraw<CoinType>(owner, amount);
        let resource_address = get_resource_address();
        coin::deposit(resource_address, payment);

        // Update reserves
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);
        let new_balance = if (coin_type == 1) { // APT
            bridge_pool.apt_reserves = bridge_pool.apt_reserves + amount;
            bridge_pool.apt_reserves
        } else { // MockUSDC
            bridge_pool.musdc_reserves = bridge_pool.musdc_reserves + amount;
            bridge_pool.musdc_reserves
        };

        // Emit event
        event::emit(ReservesAdded {
            coin_type,
            amount,
            new_balance,
            timestamp: timestamp::now_seconds(),
        });
    }

    // View functions
    #[view]
    public fun get_reserves(): (u64, u64) acquires BridgePool {
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global<BridgePool>(resource_address);
        (bridge_pool.apt_reserves, bridge_pool.musdc_reserves)
    }

    #[view]
    public fun get_bridge_stats(): (u64, u64, u64) acquires BridgePool {
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global<BridgePool>(resource_address);
        (bridge_pool.total_bridged_in, bridge_pool.total_bridged_out, bridge_pool.fee_collected)
    }

    // Helper functions
    fun generate_request_id(
        user: address,
        chain: vector<u8>,
        amount: u64,
        timestamp: u64,
    ): vector<u8> {
        let data = vector::empty<u8>();
        vector::append(&mut data, std::bcs::to_bytes(&user));
        vector::append(&mut data, chain);
        vector::append(&mut data, std::bcs::to_bytes(&amount));
        vector::append(&mut data, std::bcs::to_bytes(&timestamp));
        sha3_256(data)
    }

    fun is_bridge_paused(): bool acquires BridgePool {
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global<BridgePool>(resource_address);
        bridge_pool.paused
    }

    fun is_relayer(addr: address): bool acquires BridgePool {
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global<BridgePool>(resource_address);
        vector::contains(&bridge_pool.relayers, &addr)
    }

    fun assert_owner(addr: address) acquires BridgePool {
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global<BridgePool>(resource_address);
        assert!(addr == bridge_pool.owner, error::permission_denied(E_NOT_OWNER));
    }

    fun get_resource_address(): address {
        account::create_resource_address(&@cross_chain_swap, b"bridge_reserves")
    }

    // Admin functions
    public entry fun add_relayer(owner: &signer, relayer: address) acquires BridgePool {
        let owner_addr = signer::address_of(owner);
        assert_owner(owner_addr);
        
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);
        if (!vector::contains(&bridge_pool.relayers, &relayer)) {
            vector::push_back(&mut bridge_pool.relayers, relayer);
        };
    }

    public entry fun pause_bridge(owner: &signer) acquires BridgePool {
        let owner_addr = signer::address_of(owner);
        assert_owner(owner_addr);
        
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);
        bridge_pool.paused = true;
    }

    public entry fun unpause_bridge(owner: &signer) acquires BridgePool {
        let owner_addr = signer::address_of(owner);
        assert_owner(owner_addr);
        
        let resource_address = get_resource_address();
        let bridge_pool = borrow_global_mut<BridgePool>(resource_address);
        bridge_pool.paused = false;
    }
}