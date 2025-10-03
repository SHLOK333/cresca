/// Generic Cross-Chain Swap that supports any coin type including MockUSDC
module cross_chain_swap::generic_cross_chain_swap {
    use std::signer;
    use std::vector;
    use std::error;
    use std::option::{Self, Option};
    use std::timestamp;
    use std::event;
    use std::hash::sha3_256;
    use std::bcs;

    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use cross_chain_swap::mock_usdc::MockUSDC;

    // Error codes
    const E_NOT_OWNER: u64 = 1;
    const E_SWAP_EXISTS: u64 = 2;
    const E_SWAP_NOT_EXISTS: u64 = 3;
    const E_INVALID_TIMELOCK: u64 = 4;
    const E_SWAP_EXPIRED: u64 = 5;
    const E_SWAP_NOT_EXPIRED: u64 = 6;
    const E_INVALID_SECRET: u64 = 7;
    const E_SWAP_COMPLETED: u64 = 8;
    const E_SWAP_REFUNDED: u64 = 9;
    const E_NOT_INITIATOR: u64 = 10;
    const E_INSUFFICIENT_BALANCE: u64 = 11;
    const E_INVALID_AMOUNT: u64 = 12;
    const E_CONTRACT_PAUSED: u64 = 13;
    const E_UNSUPPORTED_COIN: u64 = 14;

    // Constants
    const MIN_TIMELOCK: u64 = 7200; // 2 hours in seconds
    const MAX_TIMELOCK: u64 = 172800; // 48 hours in seconds
    const SWAP_FEE: u64 = 10; // 0.1% (10/10000)
    const FEE_DENOMINATOR: u64 = 10000;

    // Coin type identifiers
    const COIN_TYPE_APT: u8 = 1;
    const COIN_TYPE_MUSDC: u8 = 2;

    struct Swap has store, drop {
        hashlock: vector<u8>,
        timelock: u64,
        initiator: address,
        recipient: address,
        amount: u64,
        coin_type: u8, // Track which coin type this swap uses
        completed: bool,
        refunded: bool,
        created_at: u64,
    }

    struct SwapStore has key {
        swaps: vector<Swap>,
        owner: address,
        fee_recipient: address,
        paused: bool,
        signer_cap: account::SignerCapability,
    }

    #[event]
    struct SwapInitiated has drop, store {
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        initiator: address,
        recipient: address,
        amount: u64,
        coin_type: u8,
        timelock: u64,
        created_at: u64,
    }

    #[event]
    struct SwapCompleted has drop, store {
        swap_id: vector<u8>,
        secret: vector<u8>,
        completer: address,
        completed_at: u64,
    }

    #[event]
    struct SwapRefunded has drop, store {
        swap_id: vector<u8>,
        refunder: address,
        refunded_at: u64,
    }

    // Initialize the contract with resource account
    fun init_module(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        
        // Create resource account for coin storage
        let (resource_signer, signer_cap) = account::create_resource_account(owner, b"cross_chain_swap");
        
        let swap_store = SwapStore {
            swaps: vector::empty<Swap>(),
            owner: owner_addr,
            fee_recipient: owner_addr,
            paused: false,
            signer_cap,
        };
        
        move_to(&resource_signer, swap_store);
    }

    // Generic initiate swap function for APT
    public entry fun initiate_swap_apt(
        initiator: &signer,
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        recipient: address,
        amount: u64,
        timelock: u64,
    ) acquires SwapStore {
        initiate_swap_internal<AptosCoin>(
            initiator, swap_id, hashlock, recipient, amount, timelock, COIN_TYPE_APT
        );
    }

    // Generic initiate swap function for MockUSDC
    public entry fun initiate_swap_musdc(
        initiator: &signer,
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        recipient: address,
        amount: u64,
        timelock: u64,
    ) acquires SwapStore {
        initiate_swap_internal<MockUSDC>(
            initiator, swap_id, hashlock, recipient, amount, timelock, COIN_TYPE_MUSDC
        );
    }

    // Internal generic initiate swap implementation
    fun initiate_swap_internal<CoinType>(
        initiator: &signer,
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        recipient: address,
        amount: u64,
        timelock: u64,
        coin_type: u8,
    ) acquires SwapStore {
        let initiator_addr = signer::address_of(initiator);
        let now = timestamp::now_seconds();
        
        // Validate inputs
        assert!(!is_contract_paused(), error::permission_denied(E_CONTRACT_PAUSED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            timelock >= now + MIN_TIMELOCK && timelock <= now + MAX_TIMELOCK,
            error::invalid_argument(E_INVALID_TIMELOCK)
        );
        assert!(!swap_exists(swap_id), error::already_exists(E_SWAP_EXISTS));
        assert!(vector::length(&hashlock) == 32, error::invalid_argument(E_INVALID_SECRET));

        // Check if user has sufficient balance
        let balance = coin::balance<CoinType>(initiator_addr);
        assert!(balance >= amount, error::invalid_state(E_INSUFFICIENT_BALANCE));

        // Calculate fee
        let fee_amount = (amount * SWAP_FEE) / FEE_DENOMINATOR;
        let swap_amount = amount - fee_amount;

        // Transfer tokens from initiator
        let payment = coin::withdraw<CoinType>(initiator, amount);
        
        // Transfer fee to fee recipient
        if (fee_amount > 0) {
            let fee_payment = coin::extract(&mut payment, fee_amount);
            coin::deposit(get_fee_recipient(), fee_payment);
        };

        // Store remaining coins in resource account
        let resource_address = get_resource_address();
        coin::deposit(resource_address, payment);

        // Create swap record
        let swap = Swap {
            hashlock,
            timelock,
            initiator: initiator_addr,
            recipient,
            amount: swap_amount,
            coin_type,
            completed: false,
            refunded: false,
            created_at: now,
        };

        let swap_store = borrow_global_mut<SwapStore>(get_resource_address());
        vector::push_back(&mut swap_store.swaps, swap);

        // Emit event
        event::emit(SwapInitiated {
            swap_id,
            hashlock,
            initiator: initiator_addr,
            recipient,
            amount: swap_amount,
            coin_type,
            timelock,
            created_at: now,
        });
    }

    // Generic complete swap for APT
    public entry fun complete_swap_apt(
        _completer: &signer,
        swap_id: vector<u8>,
        secret: vector<u8>,
    ) acquires SwapStore {
        complete_swap_internal<AptosCoin>(swap_id, secret, COIN_TYPE_APT);
    }

    // Generic complete swap for MockUSDC
    public entry fun complete_swap_musdc(
        _completer: &signer,
        swap_id: vector<u8>,
        secret: vector<u8>,
    ) acquires SwapStore {
        complete_swap_internal<MockUSDC>(swap_id, secret, COIN_TYPE_MUSDC);
    }

    // Internal generic complete swap implementation
    fun complete_swap_internal<CoinType>(
        swap_id: vector<u8>,
        secret: vector<u8>,
        coin_type: u8,
    ) acquires SwapStore {
        assert!(!is_contract_paused(), error::permission_denied(E_CONTRACT_PAUSED));
        
        // Get swap details and validate
        let resource_address = get_resource_address();
        let swap_store = borrow_global_mut<SwapStore>(resource_address);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow_mut(&mut swap_store.swaps, swap_index);
        
        // Validate swap state and coin type
        assert!(!swap.completed, error::invalid_state(E_SWAP_COMPLETED));
        assert!(!swap.refunded, error::invalid_state(E_SWAP_REFUNDED));
        assert!(timestamp::now_seconds() <= swap.timelock, error::invalid_state(E_SWAP_EXPIRED));
        assert!(swap.coin_type == coin_type, error::invalid_argument(E_UNSUPPORTED_COIN));
        
        // Validate secret
        let computed_hashlock = sha3_256(secret);
        assert!(computed_hashlock == swap.hashlock, error::invalid_argument(E_INVALID_SECRET));
        
        // Get recipient and amount before marking as completed
        let recipient_addr = swap.recipient;
        let transfer_amount = swap.amount;
        
        // Mark swap as completed
        swap.completed = true;
        
        // Transfer coins to recipient using resource account
        let resource_signer = account::create_signer_with_capability(&swap_store.signer_cap);
        let coins = coin::withdraw<CoinType>(&resource_signer, transfer_amount);
        coin::deposit(recipient_addr, coins);
        
        // Emit completion event
        event::emit(SwapCompleted {
            swap_id,
            secret,
            completer: recipient_addr,
            completed_at: timestamp::now_seconds(),
        });
    }

    // Generic refund for APT
    public entry fun refund_apt(
        refunder: &signer,
        swap_id: vector<u8>,
    ) acquires SwapStore {
        refund_internal<AptosCoin>(refunder, swap_id, COIN_TYPE_APT);
    }

    // Generic refund for MockUSDC
    public entry fun refund_musdc(
        refunder: &signer,
        swap_id: vector<u8>,
    ) acquires SwapStore {
        refund_internal<MockUSDC>(refunder, swap_id, COIN_TYPE_MUSDC);
    }

    // Internal generic refund implementation
    fun refund_internal<CoinType>(
        refunder: &signer,
        swap_id: vector<u8>,
        coin_type: u8,
    ) acquires SwapStore {
        assert!(!is_contract_paused(), error::permission_denied(E_CONTRACT_PAUSED));
        
        let refunder_addr = signer::address_of(refunder);
        let resource_address = get_resource_address();
        let swap_store = borrow_global_mut<SwapStore>(resource_address);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow_mut(&mut swap_store.swaps, swap_index);
        
        // Validate refund conditions
        assert!(!swap.completed, error::invalid_state(E_SWAP_COMPLETED));
        assert!(!swap.refunded, error::invalid_state(E_SWAP_REFUNDED));
        assert!(timestamp::now_seconds() > swap.timelock, error::invalid_state(E_SWAP_NOT_EXPIRED));
        assert!(refunder_addr == swap.initiator, error::permission_denied(E_NOT_INITIATOR));
        assert!(swap.coin_type == coin_type, error::invalid_argument(E_UNSUPPORTED_COIN));
        
        // Get initiator and amount before marking as refunded
        let initiator_addr = swap.initiator;
        let refund_amount = swap.amount;
        
        // Mark swap as refunded
        swap.refunded = true;
        
        // Return coins to initiator using resource account
        let resource_signer = account::create_signer_with_capability(&swap_store.signer_cap);
        let coins = coin::withdraw<CoinType>(&resource_signer, refund_amount);
        coin::deposit(initiator_addr, coins);
        
        // Emit refund event
        event::emit(SwapRefunded {
            swap_id,
            refunder: refunder_addr,
            refunded_at: timestamp::now_seconds(),
        });
    }

    // View functions
    #[view]
    public fun get_swap_details(swap_id: vector<u8>): (vector<u8>, u64, address, address, u64, u8, bool, bool, u64) acquires SwapStore {
        let resource_address = get_resource_address();
        let swap_store = borrow_global<SwapStore>(resource_address);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow(&swap_store.swaps, swap_index);
        
        (swap.hashlock, swap.timelock, swap.initiator, swap.recipient, 
         swap.amount, swap.coin_type, swap.completed, swap.refunded, swap.created_at)
    }

    // Helper functions
    fun swap_exists(swap_id: vector<u8>): bool acquires SwapStore {
        let resource_address = get_resource_address();
        let swap_store = borrow_global<SwapStore>(resource_address);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        option::is_some(&swap_index_opt)
    }

    fun find_swap_index(swaps: &vector<Swap>, swap_id: &vector<u8>): Option<u64> {
        let len = vector::length(swaps);
        let i = 0;
        while (i < len) {
            let swap = vector::borrow(swaps, i);
            // Create a unique identifier based on swap properties
            let computed_id = vector::empty<u8>();
            vector::append(&mut computed_id, swap.hashlock);
            vector::append(&mut computed_id, bcs::to_bytes(&swap.initiator));
            vector::append(&mut computed_id, bcs::to_bytes(&swap.timelock));
            let hashed_id = sha3_256(computed_id);
            
            if (hashed_id == *swap_id) {
                return option::some(i)
            };
            i = i + 1;
        };
        option::none<u64>()
    }

    fun is_contract_paused(): bool acquires SwapStore {
        let resource_address = get_resource_address();
        let swap_store = borrow_global<SwapStore>(resource_address);
        swap_store.paused
    }

    fun get_fee_recipient(): address acquires SwapStore {
        let resource_address = get_resource_address();
        let swap_store = borrow_global<SwapStore>(resource_address);
        swap_store.fee_recipient
    }

    fun get_resource_address(): address {
        account::create_resource_address(&@cross_chain_swap, b"cross_chain_swap")
    }

    // Admin functions
    public entry fun set_paused(owner: &signer, paused: bool) acquires SwapStore {
        let owner_addr = signer::address_of(owner);
        let resource_address = get_resource_address();
        let swap_store = borrow_global_mut<SwapStore>(resource_address);
        assert!(owner_addr == swap_store.owner, error::permission_denied(E_NOT_OWNER));
        swap_store.paused = paused;
    }

    public entry fun set_fee_recipient(owner: &signer, new_recipient: address) acquires SwapStore {
        let owner_addr = signer::address_of(owner);
        let resource_address = get_resource_address();
        let swap_store = borrow_global_mut<SwapStore>(resource_address);
        assert!(owner_addr == swap_store.owner, error::permission_denied(E_NOT_OWNER));
        swap_store.fee_recipient = new_recipient;
    }
}