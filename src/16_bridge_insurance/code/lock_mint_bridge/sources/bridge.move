/// Module: lock_mint_bridge
/// A simplified lock-and-mint bridge demonstrating cross-chain token bridging mechanics.
/// Locks native tokens on the source chain and tracks wrapped token operations via events.
module lock_mint_bridge::bridge;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::table::{Self, Table};
use sui::event;

// ===== Phantom type for wrapped token =====

/// Phantom type representing the wrapped version of a native token on the destination chain.
public struct WRAPPED has drop {}

// ===== Core objects =====

/// Shared vault holding locked native tokens and tracking bridge state.
public struct BridgeVault<phantom Native> has key {
    id: UID,
    /// Native tokens locked in this vault, awaiting release or bridging back.
    locked: Balance<Native>,
    /// Total amount of wrapped tokens minted (tracked for accounting).
    total_wrapped: u64,
    /// Monotonically increasing nonce for transfer identifiers.
    next_nonce: u64,
    /// Pending transfers indexed by nonce (u64).
    pending_transfers: Table<u64, BridgeTransfer>,
    /// Whether the bridge is currently paused.
    paused: bool,
    /// Address of the bridge operator.
    operator: address,
}

/// A pending or completed cross-chain bridge transfer record.
public struct BridgeTransfer has store, copy, drop {
    /// Destination chain identifier (application-specific).
    to_chain: u64,
    /// Amount of tokens being transferred.
    amount: u64,
    /// Recipient address on the destination chain (opaque bytes).
    recipient: vector<u8>,
    /// Nonce (unique identifier) for this transfer.
    nonce: u64,
    /// Whether this transfer has been executed (released/minted).
    executed: bool,
}

/// Owned capability object granting operator privileges.
public struct OperatorCap has key, store {
    id: UID,
}

// ===== Events =====

/// Emitted when native tokens are locked for cross-chain transfer.
public struct BridgeLock has copy, drop {
    vault_id: ID,
    to_chain: u64,
    amount: u64,
    recipient: vector<u8>,
    nonce: u64,
}

/// Emitted when wrapped tokens are burned to bridge back to native chain.
public struct BridgeBurn has copy, drop {
    vault_id: ID,
    to_chain: u64,
    amount: u64,
    recipient: vector<u8>,
    nonce: u64,
}

/// Emitted when wrapped tokens are minted on this chain (operator action).
public struct BridgeMint has copy, drop {
    vault_id: ID,
    amount: u64,
    recipient: address,
    nonce: u64,
}

/// Emitted when locked native tokens are released back to a user.
public struct BridgeRelease has copy, drop {
    vault_id: ID,
    amount: u64,
    recipient: address,
    nonce: u64,
}

// ===== Init =====

/// Creates a shared BridgeVault and OperatorCap for the given native token type.
/// Call this once during module setup. The vault is shared; the cap is transferred to the operator.
public fun create_vault<Native>(ctx: &mut TxContext) {
    let vault = BridgeVault<Native> {
        id: object::new(ctx),
        locked: balance::zero(),
        total_wrapped: 0,
        next_nonce: 0,
        pending_transfers: table::new(ctx),
        paused: false,
        operator: ctx.sender(),
    };
    transfer::share_object(vault);

    let cap = OperatorCap {
        id: object::new(ctx),
    };
    transfer::transfer(cap, ctx.sender());
}

// ===== Public entry functions =====

/// Lock native tokens into the vault, signaling a cross-chain transfer.
/// The caller provides a `Coin<Native>` which is absorbed into the vault's balance.
/// Emits a `BridgeLock` event so an off-chain relayer can mint wrapped tokens
/// on the destination chain.
public fun lock<Native>(
    vault: &mut BridgeVault<Native>,
    native_coin: Coin<Native>,
    to_chain: u64,
    recipient: vector<u8>,
    _ctx: &mut TxContext,
) {
    assert!(!vault.paused, EBridgePaused);

    let amount = coin::value(&native_coin);
    assert!(amount > 0, EZeroAmount);

    // Absorb the coin into the vault
    let coin_balance = coin::into_balance(native_coin);
    balance::join(&mut vault.locked, coin_balance);

    // Assign a nonce for this transfer
    let nonce = vault.next_nonce;
    vault.next_nonce = vault.next_nonce + 1;

    // Create a pending transfer record
    let transfer = BridgeTransfer {
        to_chain,
        amount,
        recipient: recipient,
        nonce,
        executed: false,
    };
    table::add(&mut vault.pending_transfers, nonce, transfer);

    event::emit(BridgeLock {
        vault_id: object::id(vault),
        to_chain,
        amount,
        recipient,
        nonce,
    });
}

/// Operator mints wrapped tokens on this chain (simplified tracking only).
/// In a production bridge this would use the `WRAPPED` TreasuryCap to mint
/// actual wrapped token Coins. Here we just track the amount and emit an event.
public fun mint_wrapped<Native>(
    _cap: &OperatorCap,
    vault: &mut BridgeVault<Native>,
    amount: u64,
    recipient: address,
    nonce: u64,
) {
    assert!(!vault.paused, EBridgePaused);
    assert!(amount > 0, EZeroAmount);

    // In production: mint actual wrapped tokens using TreasuryCap
    // Simplified: just increment the counter
    vault.total_wrapped = vault.total_wrapped + amount;

    event::emit(BridgeMint {
        vault_id: object::id(vault),
        amount,
        recipient,
        nonce,
    });
}

/// Burn wrapped tokens to initiate a bridge back to the native chain.
/// In production, the caller would provide a `Coin<WRAPPED>`.
/// Simplified: accept a native Coin (representing wrapped) and track the burn.
public fun burn_wrapped<Native>(
    vault: &mut BridgeVault<Native>,
    wrapped_coin: Coin<Native>,
    to_chain: u64,
    recipient: vector<u8>,
    _ctx: &mut TxContext,
) {
    assert!(!vault.paused, EBridgePaused);

    let amount = coin::value(&wrapped_coin);
    assert!(amount > 0, EZeroAmount);

    // Destroy the wrapped coin (in reality this would burn wrapped tokens)
    let coin_balance = coin::into_balance(wrapped_coin);
    balance::join(&mut vault.locked, coin_balance);

    // Decrease total wrapped tracking
    assert!(vault.total_wrapped >= amount, EInsufficientWrapped);
    vault.total_wrapped = vault.total_wrapped - amount;

    let nonce = vault.next_nonce;
    vault.next_nonce = vault.next_nonce + 1;

    let transfer = BridgeTransfer {
        to_chain,
        amount,
        recipient: recipient,
        nonce,
        executed: false,
    };
    table::add(&mut vault.pending_transfers, nonce, transfer);

    event::emit(BridgeBurn {
        vault_id: object::id(vault),
        to_chain,
        amount,
        recipient,
        nonce,
    });
}

/// Operator releases locked native tokens back to a user on this chain.
public fun release<Native>(
    _cap: &OperatorCap,
    vault: &mut BridgeVault<Native>,
    amount: u64,
    recipient: address,
    nonce: u64,
    ctx: &mut TxContext,
) {
    assert!(!vault.paused, EBridgePaused);
    assert!(amount > 0, EZeroAmount);

    // Ensure vault has enough locked balance
    let locked_value = balance::value(&vault.locked);
    assert!(locked_value >= amount, EInsufficientLocked);

    // Withdraw from vault and transfer to recipient
    let withdrawn = balance::split(&mut vault.locked, amount);
    let released_coin = coin::from_balance(withdrawn, ctx);
    transfer::public_transfer(released_coin, recipient);

    event::emit(BridgeRelease {
        vault_id: object::id(vault),
        amount,
        recipient,
        nonce,
    });
}

// ===== Operator controls =====

/// Pause all bridge operations.
public fun pause<Native>(_cap: &OperatorCap, vault: &mut BridgeVault<Native>) {
    vault.paused = true;
}

/// Resume bridge operations.
public fun unpause<Native>(_cap: &OperatorCap, vault: &mut BridgeVault<Native>) {
    vault.paused = false;
}

// ===== View / helper =====

/// Read the total amount of native tokens locked in the vault.
public fun locked_amount<Native>(vault: &BridgeVault<Native>): u64 {
    balance::value(&vault.locked)
}

/// Read the total wrapped token supply tracked by the vault.
public fun total_wrapped<Native>(vault: &BridgeVault<Native>): u64 {
    vault.total_wrapped
}

/// Check if the bridge is paused.
public fun is_paused<Native>(vault: &BridgeVault<Native>): bool {
    vault.paused
}

// ===== Error constants =====

const EBridgePaused: u64 = 0;
const EZeroAmount: u64 = 1;
const EInsufficientLocked: u64 = 2;
const EInsufficientWrapped: u64 = 3;
