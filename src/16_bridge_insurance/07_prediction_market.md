# 16.7 预测市场与去中心化裁决

本节从**保险与裁决**视角给出预测市场的最小模型。完整的机制拆解（条件代币、LMSR、Polymarket 架构对照、Oracle 争议窗口与 Claim）见 **第 17 章**。

## 预测市场作为保险

预测市场天然具有保险功能：

```
传统保险：
  保费 → 保单 → 索赔 → 评估 → 赔付

预测市场保险：
  购买"是"代币 → 事件发生 → 自动结算 → 赔付
```

区别在于：传统保险需要人工评估索赔，预测市场通过价格机制自动完成评估。

## 预测市场的 Move 实现

```move
module insurance::prediction_market;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EMarketClosed: vector<u8> = b"Market Closed";
#[error]
const EAlreadyResolved: vector<u8> = b"Already Resolved";
#[error]
const ENotResolved: vector<u8> = b"Not Resolved";
#[error]
const EZeroAmount: vector<u8> = b"Zero Amount";
#[error]
const EInvalidOutcome: vector<u8> = b"Invalid Outcome";
const PRECISION: u64 = 1_000_000_000;

public struct YES has copy, drop, store {}
public struct NO has copy, drop, store {}

public struct Market has key {
    id: UID,
    question: String,
    end_ms: u64,
    resolution_ms: u64,
    outcome: u8,
    resolved: bool,
    yes_supply: u64,
    no_supply: u64,
    yes_bonded: Balance<CollateralCoin>,
    no_bonded: Balance<CollateralCoin>,
    collateral_cap: TreasuryCap<CollateralCoin>,
    dispute_stake: u64,
    disputes: vector<Dispute>,
    resolver: address,
}

public struct Dispute has store {
    disputer: address,
    proposed_outcome: u8,
    stake: u64,
    evidence_hash: vector<u8>,
}

public struct MarketCreated has copy, drop {
    market_id: address,
    question: String,
    end_ms: u64,
}

public struct SharesBought has copy, drop {
    market_id: address,
    buyer: address,
    outcome: u8,
    shares: u64,
    cost: u64,
}

public struct MarketResolved has copy, drop {
    market_id: address,
    outcome: u8,
}

public fun create_market<CollateralCoin>(
    cap: &mut TreasuryCap<CollateralCoin>,
    question: String,
    end_ms: u64,
    resolution_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let market = Market {
        id: object::new(ctx),
        question,
        end_ms,
        resolution_ms,
        outcome: 0,
        resolved: false,
        yes_supply: 0,
        no_supply: 0,
        yes_bonded: balance::zero(),
        no_bonded: balance::zero(),
        collateral_cap: cap,
        dispute_stake: 0,
        disputes: vector::empty(),
        resolver: ctx.sender(),
    };
    event::emit(MarketCreated {
        market_id: object::uid_to_address(&market.id),
        question,
        end_ms,
    });
    transfer::share_object(market);
}

public fun buy_yes<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    payment: Coin<CollateralCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<YES> {
    assert!(!market.resolved, EAlreadyResolved);
    assert!(clock.timestamp_ms() < market.end_ms, EMarketClosed);
    let amount = coin::value(&payment);
    assert!(amount > 0, EZeroAmount);
    let cost = amount / 2;
    balance::join(&mut market.yes_bonded, coin::into_balance(coin::split(&mut payment, cost, ctx)));
    let shares = cost;
    market.yes_supply = market.yes_supply + shares;
    event::emit(SharesBought {
        market_id: object::uid_to_address(&market.id),
        buyer: ctx.sender(),
        outcome: 1,
        shares,
        cost,
    });
    coin::mint(&mut market.collateral_cap, shares, ctx)
}

public fun buy_no<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    payment: Coin<CollateralCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<NO> {
    assert!(!market.resolved, EAlreadyResolved);
    assert!(clock.timestamp_ms() < market.end_ms, EMarketClosed);
    let amount = coin::value(&payment);
    assert!(amount > 0, EZeroAmount);
    let cost = amount / 2;
    balance::join(&mut market.no_bonded, coin::into_balance(coin::split(&mut payment, cost, ctx)));
    let shares = cost;
    market.no_supply = market.no_supply + shares;
    event::emit(SharesBought {
        market_id: object::uid_to_address(&market.id),
        buyer: ctx.sender(),
        outcome: 0,
        shares,
        cost,
    });
    coin::mint(&mut market.collateral_cap, shares, ctx)
}

public fun resolve<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    outcome: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == market.resolver, EUnauthorized);
    assert!(!market.resolved, EAlreadyResolved);
    assert!(clock.timestamp_ms() >= market.end_ms, EMarketClosed);
    assert!(outcome == 1 || outcome == 0, EInvalidOutcome);
    market.outcome = outcome;
    market.resolved = true;
    event::emit(MarketResolved {
        market_id: object::uid_to_address(&market.id),
        outcome,
    });
}

public fun redeem_yes<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    shares: Coin<YES>,
    ctx: &mut TxContext,
): Coin<CollateralCoin> {
    assert!(market.resolved, ENotResolved);
    assert!(market.outcome == 1, EInvalidOutcome);
    let amount = coin::value(&shares);
    coin::destroy_zero(shares);
    let total_pool = balance::value(&market.yes_bonded) + balance::value(&market.no_bonded);
    let payout = amount * total_pool / (market.yes_supply + market.no_supply);
    coin::take(&mut market.yes_bonded, payout, ctx)
}

public fun redeem_no<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    shares: Coin<NO>,
    ctx: &mut TxContext,
): Coin<CollateralCoin> {
    assert!(market.resolved, ENotResolved);
    assert!(market.outcome == 0, EInvalidOutcome);
    let amount = coin::value(&shares);
    coin::destroy_zero(shares);
    let total_pool = balance::value(&market.yes_bonded) + balance::value(&market.no_bonded);
    let payout = amount * total_pool / (market.yes_supply + market.no_supply);
    coin::take(&mut market.no_bonded, payout, ctx)
}

public fun yes_price<CollateralCoin>(market: &Market<CollateralCoin>): u64 {
    let total = market.yes_supply + market.no_supply;
    if (total == 0) { return PRECISION / 2 };
    market.yes_supply * PRECISION / total
}

public fun dispute<CollateralCoin>(
    market: &mut Market<CollateralCoin>,
    proposed_outcome: u8,
    evidence_hash: vector<u8>,
    stake: Coin<CollateralCoin>,
    ctx: &mut TxContext,
) {
    let stake_amount = coin::value(&stake);
    market
        .disputes
        .push_back(Dispute {
            disputer: ctx.sender(),
            proposed_outcome,
            stake: stake_amount,
            evidence_hash,
        });
    market.dispute_stake = market.dispute_stake + stake_amount;
    coin::destroy_zero(stake);
}
```

## 预测市场的价格发现

```
YES 代币价格 = 市场认为事件发生的概率

示例：
  "Cetus 在 2024 年底前会被攻击"
  YES 价格 = $0.03 → 市场认为 3% 概率

  用户购买 $1000 面值的 YES 代币，花费 $30
  如果 Cetus 被攻击 → 获得 $1000（赔付）
  如果 Cetus 安全 → 损失 $30（保费）

这就是参数型保险——保费 = 保额 × 市场概率
```

## 去中心化裁决

当预测市场结果有争议时，需要裁决机制：

```
Kleros 模型：
  1. 争议提交 → 从陪审员池中随机选出 N 名陪审员
  2. 陪审员审查证据并投票
  3. 多数票决定结果
  4. 投票正确的陪审员获得奖励
  5. 投票错误的陪审员损失质押

博弈论保障：
  诚实投票的期望收益 > 操纵收益
  因为操纵需要控制 >50% 的陪审员
```

## 风险分析

| 风险         | 描述                                   |
| ------------ | -------------------------------------- |
| 市场操纵     | 大户通过大量交易影响 YES/NO 价格       |
| 裁决偏见     | 陪审员可能被贿赂                       |
| 流动性不足   | 小众事件的预测市场可能没有足够的流动性 |
| 事件定义歧义 | "被攻击"的定义可能有争议               |
| 先行者优势   | 知情者可以在信息公开前交易             |
