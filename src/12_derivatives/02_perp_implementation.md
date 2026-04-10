# 12.2 永续合约完整实现

## 对象设计

```move
module perp {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientMargin: u64 = 400;
    const EPositionTooSmall: u64 = 401;
    const EMarketPaused: u64 = 402;
    const ENotOwner: u64 = 403;
    const EMaintenanceMarginBreached: u64 = 404;
    const ENotLiquidatable: u64 = 405;

    struct PerpMarket<phantom Base, phantom Quote> has key {
        id: UID,
        base_reserve: Balance<Base>,
        quote_reserve: Balance<Quote>,
        insurance_fund: Balance<Quote>,
        total_long_size: u64,
        total_short_size: u64,
        index_price: u64,
        mark_price: u64,
        funding_rate_bps: i64,
        last_funding_time: u64,
        funding_interval_ms: u64,
        maintenance_margin_bps: u64,
        taker_fee_bps: u64,
        paused: bool,
    }

    struct Position<phantom Base, phantom Quote> has key, store {
        id: UID,
        market_id: ID,
        owner: address,
        size: u64,
        entry_price: u64,
        margin: u64,
        is_long: bool,
        last_funding_payment: u64,
        unrealized_pnl: i128,
    }

    struct AdminCap has key, store {
        id: UID,
        market_id: ID,
    }
}
```

## 开仓

```move
public fun open_position<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    margin_coin: Coin<Quote>,
    size: u64,
    is_long: bool,
    ctx: &mut TxContext,
): Position<Base, Quote> {
    assert!(!market.paused, EMarketPaused);
    let margin = coin::value(&margin_coin);
    assert!(margin > 0 && size > 0, EPositionTooSmall);

    let leverage = (size as u128) * 10000 / (margin as u128);
    let max_leverage = 100000 / market.maintenance_margin_bps;
    assert!(leverage <= max_leverage, EInsufficientMargin);

    update_funding(market);

    let entry_price = market.mark_price;

    if (is_long) {
        market.total_long_size = market.total_long_size + size;
    } else {
        market.total_short_size = market.total_short_size + size;
    };

    balance::join(&mut market.quote_reserve, coin::into_balance(margin_coin));

    Position<Base, Quote> {
        id: object::new(ctx),
        market_id: object::id(market),
        owner: tx_context::sender(ctx),
        size,
        entry_price,
        margin,
        is_long,
        last_funding_payment: market.last_funding_time,
        unrealized_pnl: 0,
    }
}
```

## 追加保证金

```move
public fun add_margin<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: &mut Position<Base, Quote>,
    margin_coin: Coin<Quote>,
) {
    assert!(object::id(market) == position.market_id, ENotOwner);
    let extra = coin::value(&margin_coin);
    position.margin = position.margin + extra;
    balance::join(&mut market.quote_reserve, coin::into_balance(margin_coin));
}
```

## 减仓

```move
public fun reduce_position<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: &mut Position<Base, Quote>,
    reduce_size: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(object::id(market) == position.market_id, ENotOwner);
    assert!(reduce_size <= position.size, EPositionTooSmall);

    update_funding(market);
    let pnl = calculate_pnl(position.entry_price, market.mark_price, reduce_size, position.is_long);
    let margin_delta = ((reduce_size as u128) * (position.margin as u128) / (position.size as u128)) as u64;
    let release_amount = if (pnl >= 0) {
        margin_delta + (pnl as u64)
    } else {
        let loss = (-pnl) as u64;
        if (loss >= margin_delta) { 0 } else { margin_delta - loss }
    };

    position.size = position.size - reduce_size;
    position.margin = position.margin - margin_delta;
    position.entry_price = market.mark_price;

    if (position.is_long) {
        market.total_long_size = market.total_long_size - reduce_size;
    } else {
        market.total_short_size = market.total_short_size - reduce_size;
    };

    coin::take(&mut market.quote_reserve, release_amount, ctx)
}
```

## 强制清算

```move
public fun liquidate<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: Position<Base, Quote>,
    ctx: &mut TxContext,
): Coin<Quote> {
    let pnl = calculate_pnl(
        position.entry_price,
        market.mark_price,
        position.size,
        position.is_long,
    );
    let margin_after_pnl = if (pnl >= 0) {
        position.margin + (pnl as u64)
    } else {
        let loss = (-pnl) as u64;
        if (loss >= position.margin) { 0 } else { position.margin - loss }
    };
    let effective_margin = (margin_after_pnl as u128) * 10000 / (position.size as u128);
    assert!(effective_margin < market.maintenance_margin_bps as u128, ENotLiquidatable);

    let penalty = position.margin * 500 / 10000;
    let to_insurance = penalty;
    let to_liquidator = position.margin - penalty;

    balance::join(&mut market.insurance_fund, balance::split(&mut market.quote_reserve, to_insurance));

    if (position.is_long) {
        market.total_long_size = market.total_long_size - position.size;
    } else {
        market.total_short_size = market.total_short_size - position.size;
    };

    object::delete(position);
    coin::take(&mut market.quote_reserve, to_liquidator, ctx)
}
```

## 资金费率更新

```move
fun update_funding<Base, Quote>(market: &mut PerpMarket<Base, Quote>) {
    let now = sui::clock::timestamp_ms(sui::clock::create_for_testing());
    if (now - market.last_funding_time < market.funding_interval_ms) { return };

    let premium = (market.mark_price as i128) - (market.index_price as i128);
    let new_rate = premium * 1000 / (market.index_price as i128);
    market.funding_rate_bps = new_rate as i64;
    market.last_funding_time = now;
}
```

## 保险基金

```move
public fun fund_insurance<Base, Quote>(
    _cap: &AdminCap,
    market: &mut PerpMarket<Base, Quote>,
    fund: Coin<Quote>,
) {
    balance::join(&mut market.insurance_fund, coin::into_balance(fund));
}

public fun insurance_balance<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    balance::value(&market.insurance_fund)
}
```

保险基金的用途：当清算罚金不足以覆盖仓位亏损时，用保险基金填补差额，防止坏账影响其他用户。
