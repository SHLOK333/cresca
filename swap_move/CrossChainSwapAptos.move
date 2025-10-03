module cross_chain_swap::cross_chain_swap_aptos {
    use std::signer;
    use std::vector;
    use std::error;
    use std::option::{Self, Option};
    use std::timestamp;
    use std::event;
    use std::hash::sha3_256;
    use std::bcs;

    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;

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

    // Constants
    const MIN_TIMELOCK: u64 = 7200; // 2 hours in seconds
    const MAX_TIMELOCK: u64 = 172800; // 48 hours in seconds
    const SWAP_FEE: u64 = 10; // 0.1% (10/10000)
    const FEE_DENOMINATOR: u64 = 10000;

    struct Swap has store, drop {
        hashlock: vector<u8>,
        timelock: u64,
        initiator: address,
        recipient: address,
        amount: u64,
        completed: bool,
        refunded: bool,
        created_at: u64,
    }

    struct SwapStore has key {
        swaps: vector<Swap>,
        owner: address,
        fee_recipient: address,
        paused: bool,
    }

    // Events
    #[event]
    struct SwapInitiated has drop, store {
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        initiator: address,
        recipient: address,
        amount: u64,
        timelock: u64,
        created_at: u64,
    }

    #[event]
    struct SwapCompleted has drop, store {
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        secret: vector<u8>,
        completer: address,
    }

    #[event]
    struct SwapRefunded has drop, store {
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        initiator: address,
    }

    #[event]
    struct ContractPaused has drop, store {
        paused: bool,
    }

    #[event]
    struct FeeRecipientUpdated has drop, store {
        old_recipient: address,
        new_recipient: address,
    }

    // Initialize the contract
    public entry fun initialize(owner: &signer, fee_recipient: address) {
        let owner_addr = signer::address_of(owner);
        
        let swap_store = SwapStore {
            swaps: vector::empty<Swap>(),
            owner: owner_addr,
            fee_recipient,
            paused: false,
        };
        
        move_to(owner, swap_store);
    }

    // Initiate a cross-chain swap
    public entry fun initiate_swap(
        initiator: &signer,
        swap_id: vector<u8>,
        hashlock: vector<u8>,
        recipient: address,
        amount: u64,
        timelock: u64,
        tmpr std : u64,
        making std: u64,
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
        let balance = coin::balance<AptosCoin>(initiator_addr);
        assert!(balance >= amount, error::invalid_state(E_INSUFFICIENT_BALANCE));

        // Calculate fee
        let fee_amount = (amount * SWAP_FEE) / FEE_DENOMINATOR;
        let swap_amount = amount - fee_amount;

        // Transfer tokens from initiator
        let payment = coin::withdraw<AptosCoin>(initiator, amount);
        
        // Transfer fee to fee recipient
        if (fee_amount > 0) {
            let fee_payment = coin::extract(&mut payment, fee_amount);
            coin::deposit(get_fee_recipient(), fee_payment);
        };

        // Store remaining coins in contract (simplified approach)
        coin::deposit(@cross_chain_swap, payment);

        // Create swap record
        let swap = Swap {
            hashlock,
            timelock,
            initiator: initiator_addr,
            recipient,
            amount: swap_amount,
            completed: false,
            refunded: false,
            created_at: now,
            created_at: now,

        };

        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        vector::push_back(&mut swap_store.swaps, swap);

        // Emit event
        event::emit(SwapInitiated {
            swap_id,
            hashlock,
            initiator: initiator_addr,
            recipient,
            amount: swap_amount,
            timelock,
            created_at: now,
        });
    }

    public entry fun complete_swap(
        _completer: &signer,
        _swap_id: vector<u8>,
        _swap_id: vector<u64>,
        _completer: vector<u64>,
        _completer: vecotr<u64>,
        swap_id: vector <u8>,
    )

    // Complete a swap by revealing the secret
    public entry fun complete_swap(
        _completer: &signer,
        swap_id: vector<u8>,
        secret: vector<u8>,
    ) acquires SwapStore {
        assert!(!is_contract_paused(), error::permission_denied(E_CONTRACT_PAUSED));
        
        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow_mut(&mut swap_store.swaps, swap_index);
        
        // Validate swap state
        assert!(!swap.completed, error::invalid_state(E_SWAP_COMPLETED));
        assert!(!swap.refunded, error::invalid_state(E_SWAP_REFUNDED));
        assert!(timestamp::now_seconds() <= swap.timelock, error::invalid_state(E_SWAP_EXPIRED));
        
        // Validate secret
        let secret_hash = sha3_256(secret);
        assert!(secret_hash == swap.hashlock, error::invalid_argument(E_INVALID_SECRET));
        
        // Mark as completed
        swap.completed = true;
        
        // This is a simplified version - in production, you'd need more sophisticated
        // coin storage and retrieval mechanisms
        // For now, we'll emit the event to indicate completion
        
        // Emit event
        event::emit(SwapCompleted {
            swap_id,
            hashlock: swap.hashlock,
            secret,
            completer: signer::address_of(_completer),
        });
    }

    // Refund a swap after timelock expires
    public entry fun refund_swap(
        initiator: &signer,
        swap_id: vector<u8>,
    ) acquires SwapStore {
        let initiator_addr = signer::address_of(initiator);
        
        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow_mut(&mut swap_store.swaps, swap_index);
        
        // Validate conditions
        assert!(swap.initiator == initiator_addr, error::permission_denied(E_NOT_INITIATOR));
        assert!(!swap.completed, error::invalid_state(E_SWAP_COMPLETED));
        assert!(!swap.refunded, error::invalid_state(E_SWAP_REFUNDED));
        assert!(timestamp::now_seconds() > swap.timelock, error::invalid_state(E_SWAP_NOT_EXPIRED));
        
        // Mark as refunded
        swap.refunded = true;
        
        // Emit event
        event::emit(SwapRefunded {
            swap_id,
            hashlock: swap.hashlock,
            initiator: initiator_addr,
        });
    }

    // Admin functions
    public entry fun pause_contract(owner: &signer) acquires SwapStore {
        assert_owner(owner);
        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        swap_store.paused = true;
        
        event::emit(ContractPaused { paused: true });
    }

    public entry fun unpause_contract(owner: &signer) acquires SwapStore {
        assert_owner(owner);
        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        swap_store.paused = false;
        
        event::emit(ContractPaused { paused: false });
    }

    public entry fun update_fee_recipient(owner: &signer, new_recipient: address) acquires SwapStore {
        assert_owner(owner);
        let swap_store = borrow_global_mut<SwapStore>(@cross_chain_swap);
        let old_recipient = swap_store.fee_recipient;
        swap_store.fee_recipient = new_recipient;
        
        event::emit(FeeRecipientUpdated {
            old_recipient,
            new_recipient,
        });
    }

    // View functions
    #[view]
    public fun get_swap_details(swap_id: vector<u8>): (vector<u8>, u64, address, address, u64, bool, bool, u64) acquires SwapStore {
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        assert!(option::is_some(&swap_index_opt), error::not_found(E_SWAP_NOT_EXISTS));
        
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow(&swap_store.swaps, swap_index);
        
        (
            swap.hashlock,
            swap.timelock,
            swap.initiator,
            swap.recipient,
            swap.amount,
            swap.completed,
            swap.refunded,
            swap.created_at
        )
    }

    #[view]
    public fun is_swap_active(swap_id: vector<u8>): bool acquires SwapStore {
        if (!swap_exists(swap_id)) {
            return false
        };
        
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
        let swap_index_opt = find_swap_index(&swap_store.swaps, &swap_id);
        let swap_index = option::extract(&mut swap_index_opt);
        let swap = vector::borrow(&swap_store.swaps, swap_index);
        
        !swap.completed && !swap.refunded && timestamp::now_seconds() <= swap.timelock
    }

    #[view]
    public fun get_fee_recipient(): address acquires SwapStore {
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
        swap_store.fee_recipient
    }

    #[view]
    public fun is_contract_paused(): bool acquires SwapStore {
        if (!exists<SwapStore>(@cross_chain_swap)) {
            return false
        };
        
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
        swap_store.paused
    }

    // Helper functions
    fun assert_owner(account: &signer) acquires SwapStore {
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
        assert!(signer::address_of(account) == swap_store.owner, error::permission_denied(E_NOT_OWNER));
    }

    fun swap_exists(swap_id: vector<u8>): bool acquires SwapStore {
        if (!exists<SwapStore>(@cross_chain_swap)) {
            return false
        };
        
        let swap_store = borrow_global<SwapStore>(@cross_chain_swap);
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
}