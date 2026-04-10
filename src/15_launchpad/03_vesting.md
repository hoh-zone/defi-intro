# 15.3 解锁、归属与二级市场衔接

## 为什么不全额释放

如果代币在 TGE（Token Generation Event）时全额释放，大量用户会在开盘后立即卖出，导致价格崩溃。归属机制（Vesting）通过逐步释放代币来缓解这个问题。

## 三种归属模式

### 线性归属（Linear）

代币在归属期内匀速释放。

```
总分配: 10000 tokens, 归属期: 12 个月

月 0: 0 tokens
月 1: 833 tokens
月 3: 2500 tokens
月 6: 5000 tokens
月 12: 10000 tokens（全部解锁）
```

### 悬崖归属（Cliff）

在悬崖期结束前不释放任何代币，之后线性释放。

```
总分配: 10000 tokens, 悬崖: 3 个月, 归属期: 12 个月

月 0-2: 0 tokens
月 3: 2500 tokens（悬崖结束，一次性释放 3/12）
月 6: 5000 tokens
月 12: 10000 tokens
```

### 事件触发归属

解锁条件与特定事件挂钩（如 TVL 达标、交易量达标）。

```move
struct EventVesting has store {
    total: u64,
    claimed: u64,
    milestones: vector<Milestone>,
}

struct Milestone has store {
    description: vector<u8>,
    unlock_amount: u64,
    triggered: bool,
    trigger_condition: u8,
}
```

## 领取逻辑

```move
public fun calculate_vested(
    total: u64,
    claimed: u64,
    start_time: u64,
    cliff_end: u64,
    vesting_end: u64,
    now: u64,
): u64 {
    if (now < cliff_end) { return 0 };
    let vested = if (now >= vesting_end) {
        total
    } else {
        total * (now - start_time) / (vesting_end - start_time)
    };
    if (vested > claimed) { vested - claimed } else { 0 }
}
```

核心逻辑：`可领取 = max(已归属 - 已领取, 0)`

## 二级市场衔接

归属机制影响二级市场的代币流通量：

```
TGE: 0% 流通（全部锁仓）
+3 个月: 25% 流通（悬崖结束）
+6 个月: 50% 流通
+12 个月: 100% 流通
```

流通量逐步增加意味着卖压逐步释放，而不是集中在 TGE 时爆发。但这也意味着价格可能在归属期结束后才反映真实的供需关系。
