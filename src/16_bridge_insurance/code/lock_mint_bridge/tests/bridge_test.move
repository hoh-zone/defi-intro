/// Tests for the lock_mint_bridge module.
#[test_only]
module lock_mint_bridge::bridge_test;

use lock_mint_bridge::bridge;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario;

const OPERATOR: address = @0xAD;
const USER: address = @0xB0B;

// ===== Helpers =====

/// Set up a test scenario and create the bridge vault and operator cap.
fun setup(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(OPERATOR);
    // Manually create vault since there is no init with type params
    scenario.next_tx(OPERATOR);
    {
        bridge::create_vault<SUI>(scenario.ctx());
    };
    scenario
}

/// Mint test SUI coins for a given address.
fun mint_sui(ctx: &mut TxContext, amount: u64): Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ctx)
}

// ===== Tests =====

#[test]
/// Verify that init creates the BridgeVault (shared) and OperatorCap (owned).
fun test_init_creates_objects() {
    let mut scenario = setup();

    // Operator should own the OperatorCap
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        // Cap exists — that's sufficient proof of correct creation
        scenario.return_to_sender(cap);
    };

    // BridgeVault<SUI> should be available as a shared object
    scenario.next_tx(OPERATOR);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        assert!(bridge::locked_amount(&vault) == 0);
        assert!(bridge::total_wrapped(&vault) == 0);
        assert!(!bridge::is_paused(&vault));
        test_scenario::return_shared(vault);
    };

    scenario.end();
}

#[test]
/// Lock SUI tokens into the vault and verify the locked amount increases.
fun test_lock_tokens() {
    let mut scenario = setup();

    // User locks 1000 SUI
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 1000);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        assert!(bridge::locked_amount(&vault) == 1000);
        test_scenario::return_shared(vault);
    };

    // Another user locks 500 SUI
    scenario.next_tx(OPERATOR);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 500);
        bridge::lock(&mut vault, coin, 2, b"0xOP_DEST", scenario.ctx());
        assert!(bridge::locked_amount(&vault) == 1500);
        test_scenario::return_shared(vault);
    };

    scenario.end();
}

#[test]
/// Lock tokens then release them back to a user via operator.
fun test_release_tokens() {
    let mut scenario = setup();

    // User locks 2000 SUI
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 2000);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        assert!(bridge::locked_amount(&vault) == 2000);
        test_scenario::return_shared(vault);
    };

    // Operator releases 1500 SUI back to USER
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::release(&cap, &mut vault, 1500, USER, 0, scenario.ctx());
        assert!(bridge::locked_amount(&vault) == 500);
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    // USER should have received the released coin
    scenario.next_tx(USER);
    {
        let released = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin::value(&released) == 1500);
        // Return the coin to sender for cleanup
        scenario.return_to_sender(released);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = bridge::EInsufficientLocked)]
/// Cannot release more tokens than are currently locked in the vault.
fun test_cannot_release_more_than_locked() {
    let mut scenario = setup();

    // User locks only 500 SUI
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 500);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        test_scenario::return_shared(vault);
    };

    // Operator tries to release 1000 -- should abort
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::release(&cap, &mut vault, 1000, USER, 0, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = bridge::EBridgePaused)]
/// When the bridge is paused, lock operations should fail.
fun test_pause_prevents_lock() {
    let mut scenario = setup();

    // Operator pauses the bridge
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::pause(&cap, &mut vault);
        assert!(bridge::is_paused(&vault));
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    // User tries to lock while paused -- should abort
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 1000);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        test_scenario::return_shared(vault);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = bridge::EBridgePaused)]
/// When the bridge is paused, release operations should fail.
fun test_pause_prevents_release() {
    let mut scenario = setup();

    // User locks some tokens first (while unpaused)
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 1000);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        test_scenario::return_shared(vault);
    };

    // Operator pauses the bridge
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::pause(&cap, &mut vault);
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    // Operator tries to release while paused -- should abort
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::release(&cap, &mut vault, 500, USER, 0, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}

#[test]
/// Verify that unpausing restores bridge functionality.
fun test_unpause_restores_operations() {
    let mut scenario = setup();

    // Operator pauses
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::pause(&cap, &mut vault);
        assert!(bridge::is_paused(&vault));
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    // Operator unpauses
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::unpause(&cap, &mut vault);
        assert!(!bridge::is_paused(&vault));
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    // User can now lock successfully
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        let coin = mint_sui(scenario.ctx(), 1000);
        bridge::lock(&mut vault, coin, 1, b"0xB0B_DEST", scenario.ctx());
        assert!(bridge::locked_amount(&vault) == 1000);
        test_scenario::return_shared(vault);
    };

    scenario.end();
}

#[test]
/// Verify mint_wrapped increases the total_wrapped counter.
fun test_mint_wrapped_tracking() {
    let mut scenario = setup();

    // Operator mints wrapped tokens (simplified tracking)
    scenario.next_tx(OPERATOR);
    {
        let cap = scenario.take_from_sender<bridge::OperatorCap>();
        let mut vault = scenario.take_shared<bridge::BridgeVault<SUI>>();
        bridge::mint_wrapped(&cap, &mut vault, 5000, USER, 0);
        assert!(bridge::total_wrapped(&vault) == 5000);
        test_scenario::return_shared(vault);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}
