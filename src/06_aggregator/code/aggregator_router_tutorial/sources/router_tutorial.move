/// 教学用：聚合器「Router + SwapContext」最小可编译模型（与真实 Cetus 聚合器不等价，仅演示状态与断言形状）。
/// 对应书中第 6 章；链上真实实现以官方部署模块为准。
#[allow(unused_mut_parameter, duplicate_alias)]
module aggregator_router_tutorial::router_tutorial;

use std::option::{Self, Option};
use std::string::String;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

// === 错误码（与书中 6.x 讲解对照） ===
#[error]
const EMaxInExceeded: vector<u8> = b"Max In Exceeded";
#[error]
const EBelowMinOut: vector<u8> = b"Below Min Out";

/// 一笔多跳 swap 在链上的「上下文」：记住报价 id、最小输出、输入余额与已累积输出。
/// 真实系统里还会带协议费接收方、期望输出等字段；此处压缩为教学核心。
public struct SwapContext<phantom CoinIn, phantom CoinOut> has key, store {
    id: UID,
    quote_id: String,
    /// 用户愿意接受的 **最小** 输出量（滑点底限）
    min_out: u64,
    /// `none` = v1 入口；`some(max)` = v2 入口已在构造时校验输入 ≤ max
    max_in: Option<u64>,
    /// 尚未被各 DEX 腿消耗的输入（多跳时会逐步 split）
    pending_in: Balance<CoinIn>,
    /// 各腿 swap 完成后 **汇入** 的输出余额
    out_acc: Balance<CoinOut>,
}

// ---------------------------------------------------------------------------
// 构造：对应 TS `router::new_swap_context` / `new_swap_context_v2`
// ---------------------------------------------------------------------------

/// v1：只记录 min_out，不在链上校验「输入上限」（依赖前端与链下报价）
public fun new_swap_context<CoinIn, CoinOut>(
    quote_id: String,
    min_out: u64,
    coin_in: Coin<CoinIn>,
    ctx: &mut TxContext,
): SwapContext<CoinIn, CoinOut> {
    SwapContext {
        id: object::new(ctx),
        quote_id,
        min_out,
        max_in: option::none(),
        pending_in: coin::into_balance(coin_in),
        out_acc: balance::zero(),
    }
}

/// v2：构造时断言 `coin_in` 数量不超过 `max_in`（对应 TS `new_swap_context_v2`）
public fun new_swap_context_v2<CoinIn, CoinOut>(
    quote_id: String,
    max_in: u64,
    min_out: u64,
    coin_in: Coin<CoinIn>,
    ctx: &mut TxContext,
): SwapContext<CoinIn, CoinOut> {
    assert!(coin::value(&coin_in) <= max_in, EMaxInExceeded);
    SwapContext {
        id: object::new(ctx),
        quote_id,
        min_out,
        max_in: option::some(max_in),
        pending_in: coin::into_balance(coin_in),
        out_acc: balance::zero(),
    }
}

/// 某一 DEX 腿执行完后，把产出的 `Coin<CoinOut>` 并入上下文（真实链上由聚合器包装模块调用）。
public fun record_leg_output<CoinIn, CoinOut>(
    sc: &mut SwapContext<CoinIn, CoinOut>,
    out_coin: Coin<CoinOut>,
) {
    balance::join(&mut sc.out_acc, coin::into_balance(out_coin));
}

// ---------------------------------------------------------------------------
// 收尾：对应 TS `router::confirm_swap`
// ---------------------------------------------------------------------------

/// 校验累积输出 ≥ min_out，销毁上下文，把 **剩余输入** 与 **输出币** 交还给调用方打包后续 transfer。
public fun confirm_swap<CoinIn, CoinOut>(
    sc: SwapContext<CoinIn, CoinOut>,
    ctx: &mut TxContext,
): (Coin<CoinIn>, Coin<CoinOut>) {
    let SwapContext {
        id,
        quote_id: _,
        min_out,
        max_in: _,
        pending_in,
        out_acc,
    } = sc;
    object::delete(id);
    assert!(balance::value(&out_acc) >= min_out, EBelowMinOut);
    (coin::from_balance(pending_in, ctx), coin::from_balance(out_acc, ctx))
}
