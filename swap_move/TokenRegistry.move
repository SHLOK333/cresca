module cross_chain_swap::token_registry {
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use std::error;
    use std::option::{Self, Option};
    use std::event;
    use std::type_info::{Self, TypeInfo};

    // Error codes
    const E_NOT_OWNER: u64 = 1;
    const E_TOKEN_EXISTS: u64 = 2;
    const E_TOKEN_NOT_EXISTS: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_CONTRACT_PAUSED: u64 = 5;

    struct TokenInfo has store, copy, drop {
        is_supported: bool,
        min_amount: u64,
        max_amount: u64,
        added_at: u64,
        name: String,
        symbol: String,
        decimals: u8,
    }

    struct CrossChainMapping has store, copy, drop {
        ethereum_address: String,
        chain_name: String,
    }

    struct TokenRegistry has key {
        supported_tokens: vector<TypeInfo>,
        token_info: vector<TokenInfo>,
        cross_chain_mappings: vector<CrossChainMapping>,
        owner: address,
        paused: bool,
    }

    // Events
    #[event]
    struct TokenAdded has drop, store {
        token_type: TypeInfo,
        name: String,
        symbol: String,
        decimals: u8,
        min_amount: u64,
        max_amount: u64,
    }

    #[event]
    struct TokenRemoved has drop, store {
        token_type: TypeInfo,
    }

    #[event]
    struct TokenLimitsUpdated has drop, store {
        token_type: TypeInfo,
        min_amount: u64,
        max_amount: u64,
    }

    #[event]
    struct CrossChainMappingSet has drop, store {
        token_type: TypeInfo,
        ethereum_address: String,
        chain_name: String,
    }

    #[event]
    struct ContractPaused has drop, store {
        paused: bool,
    }

    // Initialize the registry
    public entry fun initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        
        let registry = TokenRegistry {
            supported_tokens: vector::empty<TypeInfo>(),
            token_info: vector::empty<TokenInfo>(),
            cross_chain_mappings: vector::empty<CrossChainMapping>(),
            owner: owner_addr,
            paused: false,
        };
        
        move_to(owner, registry);
    }

    // Add a supported token
    public entry fun add_token<CoinType>(
        owner: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        min_amount: u64,
        max_amount: u64,
    ) acquires TokenRegistry {
        assert_owner(owner);
        assert!(!is_contract_paused(), error::permission_denied(E_CONTRACT_PAUSED));
        assert!(max_amount >= min_amount, error::invalid_argument(E_INVALID_AMOUNT));
        
        let token_type = type_info::type_of<CoinType>();
        assert!(!is_token_supported_internal(token_type), error::already_exists(E_TOKEN_EXISTS));
        
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        
        let token_info = TokenInfo {
            is_supported: true,
            min_amount,
            max_amount,
            added_at: std::timestamp::now_seconds(),
            name,
            symbol,
            decimals,
        };
        
        vector::push_back(&mut registry.supported_tokens, token_type);
        vector::push_back(&mut registry.token_info, token_info);
        
        event::emit(TokenAdded {
            token_type,
            name,
            symbol,
            decimals,
            min_amount,
            max_amount,
        });
    }

    // Remove a supported token
    public entry fun remove_token<CoinType>(owner: &signer) acquires TokenRegistry {
        assert_owner(owner);
        
        let token_type = type_info::type_of<CoinType>();
        assert!(is_token_supported_internal(token_type), error::not_found(E_TOKEN_NOT_EXISTS));
        
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        
        let token_index_opt = find_token_index(&registry.supported_tokens, &token_type);
        if (option::is_some(&token_index_opt)) {
            let token_index = option::extract(&mut token_index_opt);
            vector::swap_remove(&mut registry.supported_tokens, token_index);
            
            let token_info = vector::borrow_mut(&mut registry.token_info, token_index);
            token_info.is_supported = false;
        };
        
        event::emit(TokenRemoved { token_type });
    }

    // Update token limits
    public entry fun update_token_limits<CoinType>(
        owner: &signer,
        min_amount: u64,
        max_amount: u64,
    ) acquires TokenRegistry {
        assert_owner(owner);
        assert!(max_amount >= min_amount, error::invalid_argument(E_INVALID_AMOUNT));
        
        let token_type = type_info::type_of<CoinType>();
        assert!(is_token_supported_internal(token_type), error::not_found(E_TOKEN_NOT_EXISTS));
        
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        let token_index_opt = find_token_index(&registry.supported_tokens, &token_type);
        
        if (option::is_some(&token_index_opt)) {
            let token_index = option::extract(&mut token_index_opt);
            let token_info = vector::borrow_mut(&mut registry.token_info, token_index);
            token_info.min_amount = min_amount;
            token_info.max_amount = max_amount;
        };
        
        event::emit(TokenLimitsUpdated {
            token_type,
            min_amount,
            max_amount,
        });
    }

    // Set cross-chain mapping
    public entry fun set_cross_chain_mapping<CoinType>(
        owner: &signer,
        ethereum_address: String,
        chain_name: String,
    ) acquires TokenRegistry {
        assert_owner(owner);
        
        let token_type = type_info::type_of<CoinType>();
        assert!(is_token_supported_internal(token_type), error::not_found(E_TOKEN_NOT_EXISTS));
        
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        
        let mapping = CrossChainMapping {
            ethereum_address,
            chain_name,
        };
        
        vector::push_back(&mut registry.cross_chain_mappings, mapping);
        
        event::emit(CrossChainMappingSet {
            token_type,
            ethereum_address,
            chain_name,
        });
    }

    // Admin functions
    public entry fun pause_contract(owner: &signer) acquires TokenRegistry {
        assert_owner(owner);
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        registry.paused = true;
        
        event::emit(ContractPaused { paused: true });
    }

    public entry fun unpause_contract(owner: &signer) acquires TokenRegistry {
        assert_owner(owner);
        let registry = borrow_global_mut<TokenRegistry>(@cross_chain_swap);
        registry.paused = false;
        
        event::emit(ContractPaused { paused: false });
    }

    // View functions
    #[view]
    public fun is_token_supported<CoinType>(): bool acquires TokenRegistry {
        let token_type = type_info::type_of<CoinType>();
        is_token_supported_internal(token_type)
    }

    #[view]
    public fun get_token_info<CoinType>(): (bool, u64, u64, u64, String, String, u8) acquires TokenRegistry {
        let token_type = type_info::type_of<CoinType>();
        
        if (!exists<TokenRegistry>(@cross_chain_swap)) {
            return (false, 0, 0, 0, string::utf8(b""), string::utf8(b""), 0)
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        let token_index_opt = find_token_index(&registry.supported_tokens, &token_type);
        
        if (option::is_none(&token_index_opt)) {
            return (false, 0, 0, 0, string::utf8(b""), string::utf8(b""), 0)
        };
        
        let token_index = option::extract(&mut token_index_opt);
        let token_info = vector::borrow(&registry.token_info, token_index);
        
        (
            token_info.is_supported,
            token_info.min_amount,
            token_info.max_amount,
            token_info.added_at,
            token_info.name,
            token_info.symbol,
            token_info.decimals
        )
    }

    #[view]
    public fun get_supported_tokens(): vector<TypeInfo> acquires TokenRegistry {
        if (!exists<TokenRegistry>(@cross_chain_swap)) {
            return vector::empty<TypeInfo>()
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        registry.supported_tokens
    }

    #[view]
    public fun is_amount_valid<CoinType>(amount: u64): bool acquires TokenRegistry {
        let token_type = type_info::type_of<CoinType>();
        
        if (!is_token_supported_internal(token_type)) {
            return false
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        let token_index_opt = find_token_index(&registry.supported_tokens, &token_type);
        
        if (option::is_none(&token_index_opt)) {
            return false
        };
        
        let token_index = option::extract(&mut token_index_opt);
        let token_info = vector::borrow(&registry.token_info, token_index);
        
        amount >= token_info.min_amount && amount <= token_info.max_amount
    }

    #[view]
    public fun get_cross_chain_mapping(ethereum_address: String, chain_name: String): Option<String> acquires TokenRegistry {
        if (!exists<TokenRegistry>(@cross_chain_swap)) {
            return option::none<String>()
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        let len = vector::length(&registry.cross_chain_mappings);
        let i = 0;
        
        while (i < len) {
            let mapping = vector::borrow(&registry.cross_chain_mappings, i);
            if (mapping.ethereum_address == ethereum_address && mapping.chain_name == chain_name) {
                return option::some(mapping.ethereum_address)
            };
            i = i + 1;
        };
        
        option::none<String>()
    }

    #[view]
    public fun is_contract_paused(): bool acquires TokenRegistry {
        if (!exists<TokenRegistry>(@cross_chain_swap)) {
            return false
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        registry.paused
    }

    // Helper functions
    fun assert_owner(account: &signer) acquires TokenRegistry {
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        assert!(signer::address_of(account) == registry.owner, error::permission_denied(E_NOT_OWNER));
    }

    fun is_token_supported_internal(token_type: TypeInfo): bool acquires TokenRegistry {
        if (!exists<TokenRegistry>(@cross_chain_swap)) {
            return false
        };
        
        let registry = borrow_global<TokenRegistry>(@cross_chain_swap);
        let token_index_opt = find_token_index(&registry.supported_tokens, &token_type);
        
        if (option::is_none(&token_index_opt)) {
            return false
        };
        
        let token_index = option::extract(&mut token_index_opt);
        let token_info = vector::borrow(&registry.token_info, token_index);
        token_info.is_supported
    }

    fun find_token_index(tokens: &vector<TypeInfo>, target_type: &TypeInfo): Option<u64> {
        let len = vector::length(tokens);
        let i = 0;
        
        while (i < len) {
            let token_type = vector::borrow(tokens, i);
            if (token_type == target_type) {
                return option::some(i)
            };
            i = i + 1;
        };
        
        option::none<u64>()
    }
}