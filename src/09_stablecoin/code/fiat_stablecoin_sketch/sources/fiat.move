/// 教学用：法币抵押稳定币在链上的**最小角色模型**。
///
/// 真实 USDC/USDT：储备与审计在链下；链上表现为受控的 `TreasuryCap` 铸造/销毁权限。
/// 本模块**不**实现储备证明或合规逻辑，只展示「谁有权增减供给」这一层。
module fiat_stablecoin_sketch::fiat;

use std::option;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

/// 链上代币类型；模块 `fiat` 的一次性见证（OTW）同名大写即为 `FIAT`。
public struct FIAT has drop {}

public struct IssuerCap has key, store {
    id: UID,
}

public struct FiatTreasury has key {
    id: UID,
    cap: TreasuryCap<FIAT>,
}

fun init(witness: FIAT, ctx: &mut TxContext) {
    let (treasury_cap, meta) = coin::create_currency<FIAT>(
        witness,
        6,
        b"FIAT",
        b"Fiat Sketch USD",
        b"Educational: issuer-controlled supply",
        option::none(),
        ctx,
    );
    transfer::share_object(FiatTreasury {
        id: object::new(ctx),
        cap: treasury_cap,
    });
    transfer::public_freeze_object(meta);
    transfer::transfer(
        IssuerCap { id: object::new(ctx) },
        ctx.sender(),
    );
}

public fun issuer_mint(
    _: &IssuerCap,
    treasury: &mut FiatTreasury,
    to: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    let c = coin::mint(&mut treasury.cap, amount, ctx);
    transfer::public_transfer(c, to);
}

public fun issuer_burn(_: &IssuerCap, treasury: &mut FiatTreasury, c: Coin<FIAT>) {
    coin::burn(&mut treasury.cap, c);
}
