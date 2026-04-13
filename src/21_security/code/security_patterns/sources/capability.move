module security_patterns::capability;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EInsufficientBalance: vector<u8> = b"Insufficient Balance";

public struct ProtectedVault<phantom T> has key {
    id: UID,
    balance: Balance<T>,
}

public struct VaultCap has key, store {
    id: UID,
    vault_id: ID,
}

public fun create_vault<T>(ctx: &mut TxContext): VaultCap {
    let vault = ProtectedVault<T> {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    let vault_id = object::id(&vault);
    transfer::share_object(vault);
    VaultCap { id: object::new(ctx), vault_id }
}

/// Anyone can deposit (no cap needed)
public fun deposit<T>(vault: &mut ProtectedVault<T>, coin: Coin<T>) {
    balance::join(&mut vault.balance, coin::into_balance(coin));
}

/// Only cap holder can withdraw
public fun withdraw<T>(cap: &VaultCap, vault: &mut ProtectedVault<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(object::id(vault) == cap.vault_id, EUnauthorized);
    assert!(balance::value(&vault.balance) >= amount, EInsufficientBalance);
    coin::take(&mut vault.balance, amount, ctx)
}

/// Emergency drain (requires cap)
public fun emergency_withdraw<T>(cap: &VaultCap, vault: &mut ProtectedVault<T>, ctx: &mut TxContext): Coin<T> {
    assert!(object::id(vault) == cap.vault_id, EUnauthorized);
    let amount = balance::value(&vault.balance);
    coin::take(&mut vault.balance, amount, ctx)
}

/// Transfer cap to new address
public fun transfer_cap(cap: VaultCap, recipient: address) {
    transfer::transfer(cap, recipient);
}

public fun balance<T>(vault: &ProtectedVault<T>): u64 {
    balance::value(&vault.balance)
}
