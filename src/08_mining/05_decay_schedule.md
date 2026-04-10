# 8.5 衰减模型与排放调度

## 为什么需要衰减

流动性挖矿如果持续以固定速率释放奖励，会面临两个问题：

1. **通胀失控**：代币无限增发，价值持续稀释
2. **激励钝化**：用户习惯了固定奖励，无法引导行为变化

解决方案：**奖励随时间衰减**。常见的衰减模型：

```
线性衰减：每期减少固定数量
  reward(t) = R₀ - k × t

阶梯衰减：每期保持一段时间不变，然后跳降
  reward(t) = R₀ / 2^(t / T)

指数衰减：每期按固定比例减少
  reward(t) = R₀ × e^(-λt)
```

## 三种衰减器的 Move 实现

### 线性衰减

```move
module liquidity_mining::linear_decay {
    use sui::clock::Clock;

    public struct LinearDecay has store {
        initial_rate: u64,
        decay_per_ms: u64,
        start_ms: u64,
        duration_ms: u64,
        min_rate: u64,
    }

    public fun new(
        initial_rate: u64,
        duration_ms: u64,
        min_rate: u64,
        start_ms: u64,
    ): LinearDecay {
        let decay_per_ms = (initial_rate - min_rate) / duration_ms;
        LinearDecay {
            initial_rate,
            decay_per_ms,
            start_ms,
            duration_ms,
            min_rate,
        }
    }

    public fun current_rate(decay: &LinearDecay, clock: &Clock): u64 {
        let now = clock.timestamp_ms();
        if (now <= decay.start_ms) {
            return decay.initial_rate
        };
        let elapsed = now - decay.start_ms;
        if (elapsed >= decay.duration_ms) {
            return decay.min_rate
        };
        let decayed = decay.decay_per_ms * elapsed;
        if (decayed >= decay.initial_rate) {
            decay.min_rate
        } else {
            let rate = decay.initial_rate - decayed;
            if (rate < decay.min_rate) { decay.min_rate } else { rate }
        }
    }
}
```

### 阶梯衰减（Epoch 式）

```move
module liquidity_mining::epoch_decay {
    use sui::clock::Clock;

    public struct EpochDecay has store {
        rates: vector<u64>,
        epoch_duration_ms: u64,
        start_ms: u64,
    }

    public fun new(
        rates: vector<u64>,
        epoch_duration_ms: u64,
        start_ms: u64,
    ): EpochDecay {
        EpochDecay {
            rates,
            epoch_duration_ms,
            start_ms,
        }
    }

    public fun current_rate(decay: &EpochDecay, clock: &Clock): u64 {
        let now = clock.timestamp_ms();
        if (now < decay.start_ms) {
            return *decay.rates.borrow(0)
        };
        let elapsed = now - decay.start_ms;
        let epoch_index = (elapsed / decay.epoch_duration_ms);
        let num_epochs = decay.rates.length();
        if (epoch_index >= num_epochs) {
            *decay.rates.borrow(num_epochs - 1)
        } else {
            *decay.rates.borrow(epoch_index)
        }
    }

    public fun current_epoch(decay: &EpochDecay, clock: &Clock): u64 {
        let now = clock.timestamp_ms();
        if (now < decay.start_ms) { return 0 };
        (now - decay.start_ms) / decay.epoch_duration_ms
    }
}
```

使用示例：

```move
let rates = vector[1000, 800, 600, 400, 200, 100];
let epoch_decay = epoch_decay::new(rates, 30 * 24 * 3600 * 1000, start_ms);
```

6 个 epoch，每个 30 天，奖励从 1000 降到 100 token/天。

### 指数衰减

```move
module liquidity_mining::exponential_decay {
    use sui::clock::Clock;

    const PRECISION: u64 = 1_000_000_000;

    public struct ExponentialDecay has store {
        initial_rate: u64,
        half_life_ms: u64,
        start_ms: u64,
        min_rate: u64,
    }

    public fun new(
        initial_rate: u64,
        half_life_ms: u64,
        min_rate: u64,
        start_ms: u64,
    ): ExponentialDecay {
        ExponentialDecay {
            initial_rate,
            half_life_ms,
            start_ms,
            min_rate,
        }
    }

    public fun current_rate(decay: &ExponentialDecay, clock: &Clock): u64 {
        let now = clock.timestamp_ms();
        if (now <= decay.start_ms) {
            return decay.initial_rate
        };
        let elapsed = now - decay.start_ms;
        let half_lives_elapsed = (elapsed * PRECISION) / decay.half_life_ms;
        let factor = pow_1_over_2(half_lives_elapsed);
        let rate = decay.initial_rate * factor / PRECISION;
        if (rate < decay.min_rate) { decay.min_rate } else { rate }
    }

    fun pow_1_over_2(exponent_scaled: u64): u64 {
        if (exponent_scaled == 0) { return PRECISION };
        let result = PRECISION;
        let i = 0;
        while (i < 60 && result > 1) {
            if ((exponent_scaled >> i) & 1 == 1) {
                result = result / 2;
            };
            i = i + 1;
        };
        result
    }
}
```

## 排放调度器：将衰减器接入挖矿合约

```move
module liquidity_mining::emission_scheduler {
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use liquidity_mining::epoch_decay::{Self, EpochDecay};

    const E_UNAUTHORIZED: u64 = 0;
    const E_INSUFFICIENT_BALANCE: u64 = 1;

    public struct EmissionController<phantom RewardCoin> has key {
        id: UID,
        treasury: Coin<RewardCoin>,
        decay: EpochDecay,
        last_collection_ms: u64,
        uncollected_reward: u64,
        admin: address,
    }

    public fun create<RewardCoin>(
        treasury: Coin<RewardCoin>,
        rates: vector<u64>,
        epoch_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let controller = EmissionController<RewardCoin> {
            id: object::new(ctx),
            treasury,
            decay: epoch_decay::new(rates, epoch_ms, clock.timestamp_ms()),
            last_collection_ms: clock.timestamp_ms(),
            uncollected_reward: 0,
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(controller);
    }

    public fun collect<RewardCoin>(
        controller: &mut EmissionController<RewardCoin>,
        clock: &Clock,
    ): u64 {
        let now = clock.timestamp_ms();
        if (now <= controller.last_collection_ms) { return 0 };
        let elapsed = now - controller.last_collection_ms;
        let rate = epoch_decay::current_rate(&controller.decay, clock);
        let reward = rate * elapsed;
        controller.last_collection_ms = now;
        controller.uncollected_reward = controller.uncollected_reward + reward;
        controller.uncollected_reward
    }

    public fun withdraw_reward<RewardCoin>(
        controller: &mut EmissionController<RewardCoin>,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<RewardCoin> {
        assert!(tx_context::sender(ctx) == controller.admin, E_UNAUTHORIZED);
        assert!(controller.uncollected_reward >= amount, E_INSUFFICIENT_BALANCE);
        controller.uncollected_reward = controller.uncollected_reward - amount;
        coin::take(&mut controller.treasury, amount, ctx)
    }

    public fun current_emission_rate<RewardCoin>(
        controller: &EmissionController<RewardCoin>,
        clock: &Clock,
    ): u64 {
        epoch_decay::current_rate(&controller.decay, clock)
    }

    public fun treasury_balance<RewardCoin>(
        controller: &EmissionController<RewardCoin>,
    ): u64 {
        coin::value(&controller.treasury)
    }
}
```

## 三种衰减对比

| 模型 | 优点 | 缺点 | 适用场景 |
|---|---|---|---|
| 线性衰减 | 可预测、简单 | 后期衰减太慢或太快 | 固定预算的项目 |
| 阶梯衰减 | 每个 epoch 内稳定，可精确规划 | epoch 切换时 APR 突变 | Sui 生态常用（按 epoch 调整） |
| 指数衰减 | 前期快速衰减，后期长尾 | 前期对 LP 不友好 | 有明确半衰期的项目 |

## Sui Epoch 与衰减

Sui 的 epoch 约为 1 天。很多 Sui 协议将衰减周期对齐到 epoch：

```
Epoch 1-30:   1000 token/epoch
Epoch 31-60:  500 token/epoch
Epoch 61-90:  250 token/epoch
Epoch 91-120: 125 token/epoch
```

这本质上是阶梯衰减。好处是每个 epoch 内奖励稳定，用户可以精确计算 APR。

## 风险分析

| 风险 | 描述 |
|---|---|
| 衰减过快 | 前期吸引的 LP 在奖励骤降时集体撤离 |
| 衰减过慢 | 代币持续通胀，长期持有者被严重稀释 |
| 国库耗尽 | 排放速度超过国库余额，合约在 claim 时 revert |
| 治理延迟 | 阶梯衰减需要治理投票调整，可能反应太慢 |
