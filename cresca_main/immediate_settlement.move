module hyperperp::immediate_settlement {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use hyperperp::errors;
    use hyperperp::events;

    // Execute a trade immediately on-chain
    public entry fun execute_trade<T>(
        admin: &signer,
        taker_address: address,
        maker_address: address,
        market_id: u64,
        size: u128,
        price: u64,
        is_taker_long: bool,
    ) {
        // Only admin can execute trades (the matching engine)
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @hyperperp, errors::e_not_authorized());

        // Create trade execution event
        let trade_event = events::new_trade_execution_event(
            taker_address,
            maker_address,
            market_id,
            size,
            price,
            is_taker_long,
            timestamp::now_microseconds(),
            b"immediate_trade" // Simple trade ID
        );

        // Emit the event through the existing events system
        events::emit_trade_executed(@hyperperp, trade_event);
    }

    // Simple check function for initialization
    public fun is_enabled(): bool {
        // For now, always enabled if the module exists
        true
    }
}