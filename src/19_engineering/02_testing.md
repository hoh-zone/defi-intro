# 19.2 测试策略：单元、场景与对抗测试

## 三层测试

### 第一层：单元测试

测试单个函数的正确性。每个测试只验证一个行为。

```move
#[test]
fun test_calculate_pnl_long_profit() {
    let pnl = perp_math::calculate_pnl(40000, 44000, 100000000, true);
    assert!(pnl == 10000000);
}

#[test]
fun test_calculate_pnl_short_loss() {
    let pnl = perp_math::calculate_pnl(40000, 44000, 100000000, false);
    assert!(pnl < 0);
}

#[test]
fun test_calculate_pnl_zero_size() {
    let pnl = perp_math::calculate_pnl(40000, 44000, 0, true);
    assert!(pnl == 0);
}

#[test]
fun test_exchange_rate_empty_pool() {
    let rate = lsdk::exchange_rate(&empty_pool);
    assert!(rate == 1000000000);
}

#[test]
fun test_share_calculation_first_deposit() {
    let shares = amm::calculate_shares(1000, 0, 0);
    assert!(shares == sqrt(1000 * 0));
}

#[test]
fun test_share_calculation_subsequent_deposit() {
    let shares = amm::calculate_shares(500, 1000, 1000);
    assert!(shares == 500);
}
```

### 第二层：场景测试

测试完整的用户流程。

```move
#[test]
fun test_full_lending_cycle() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = scenario.ctx();

    let pool = create_test_pool(10000000, 200, ctx);
    let deposit_pos = lending::deposit(&mut pool, coin::mint_for_testing<SUI>(5000000, ctx), ctx);

    scenario.next_tx(@0xB);
    let borrow_pos = lending::borrow(&mut pool, 2000000, &vector[&deposit_pos], ctx);

    scenario.next_tx(@0xB);
    lending::repay(&mut pool, borrow_pos, coin::mint_for_testing<USDC>(2000000, ctx), ctx);

    scenario.next_tx(@0xA);
    lending::withdraw(&mut pool, deposit_pos, ctx);
}
```

### 第三层：对抗测试

测试攻击场景和异常输入。

```move
#[test]
#[expected_failure(abort_code = errors::EHealthFactorTooLow)]
fun test_borrow_exceeds_collateral() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = scenario.ctx();
    let pool = create_test_pool(10000000, 200, ctx);
    let deposit_pos = lending::deposit(&mut pool, coin::mint_for_testing<SUI>(1000000, ctx), ctx);
    lending::borrow(&mut pool, 2000000, &vector[&deposit_pos], ctx);
}

#[test]
#[expected_failure(abort_code = errors::EInsufficientLiquidity)]
fun test_withdraw_more_than_deposited() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = scenario.ctx();
    let pool = create_test_pool(10000000, 200, ctx);
    let pos = lending::deposit(&mut pool, coin::mint_for_testing<SUI>(1000, ctx), ctx);
    let coin = lending::withdraw(&mut pool, pos, ctx);
    assert!(coin::value(&coin) == 1000);
}

#[test]
#[expected_failure(abort_code = errors::EPriceStale)]
fun test_stale_price_rejected() {
    let mut config = create_test_config(300000, 500);
    let feed = create_stale_feed(1000, 0);
    oracle::safe_read_price(&config, &feed, 1000);
}

#[test]
#[expected_failure(abort_code = errors::EDevTooHigh)]
fun test_price_deviation_rejected() {
    let mut config = create_test_config(300000, 500);
    config.max_deviation_bps = 1000;
    let feed = create_fresh_feed(2000);
    oracle::safe_read_price(&config, &feed, 1000);
}
```

## 测试矩阵

|        | 正常       | 边界         | 异常       | 对抗       |
| ------ | ---------- | ------------ | ---------- | ---------- |
| 初始化 | 标准参数   | 极端参数     | 零值参数   | 无效参数   |
| 存款   | 正常金额   | u64::MAX     | 0 金额     | 重复存款   |
| 借款   | 有抵押借款 | 100% 抵押率  | 无抵押     | 超额借款   |
| 清算   | 正常清算   | 刚好跌破阈值 | 已偿还仓位 | 自我清算   |
| 利率   | 正常利用率 | 0% / 100%    | 空池子     | 操纵利用率 |
| 预言机 | 正常价格   | 剧烈波动     | 过期价格   | 被操纵价格 |
