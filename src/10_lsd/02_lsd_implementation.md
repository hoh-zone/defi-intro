# 10.2 LST 凭证实现与二次流动性

## LST 的两种实现方式

### 1. Rebasing（升值型）

LST 的数量不变，但每个 LST 对应的 SUI 数量随时间增长。

```move
public struct StakedSUI has key {
    id: UID,
    principal: Balance<SUI>,
    pool_id: ID,
    activated_at_epoch: u64,
}

public fun exchange_rate(pool: &StakingPool): u64 {
    let total_staked = balance::value(&pool.staked_sui);
    let total_lsst = pool.total_lsst_supply;
    if (total_lsst == 0) { return 1000000000 };
    total_staked * 1000000000 / total_lsst
}

public fun redeem(pool: &mut StakingPool, lsst_amount: u64, ctx: &mut TxContext): Coin<SUI> {
    let rate = exchange_rate(pool);
    let sui_amount = lsst_amount * rate / 1000000000;
    pool.total_lsst_supply = pool.total_lsst_supply - lsst_amount;
    coin::take(&mut pool.staked_sui, sui_amount, ctx)
}
```

### 2. Non-rebasing（数量增长型）

LST 与 SUI 的兑换率固定为 1:1，但用户通过 staking_reward 获得额外的 LST。

```move
public struct LiquidStakingPool has key {
    id: UID,
    staked_sui: Balance<SUI>,
    lst_supply: u64,
    reward_pool: Balance<SUI>,
    last_reward_epoch: u64,
}

public fun stake(
    pool: &mut LiquidStakingPool,
    sui_coin: Coin<SUI>,
    ctx: &mut TxContext,
): LST {
    let amount = coin::value(&sui_coin);
    balance::join(&mut pool.staked_sui, coin::into_balance(sui_coin));
    pool.lst_supply = pool.lst_supply + amount;
    LST {
        id: object::new(ctx),
        amount,
    }
}

public fun claim_reward(
    pool: &mut LiquidStakingPool,
    lst: &LST,
    ctx: &mut TxContext,
): Coin<SUI> {
    let reward = calculate_reward(pool, lst);
    coin::take(&mut pool.reward_pool, reward, ctx)
}
```

## LST 承载的三种权利

1. **经济所有权**：LST 代表底层 SUI 的所有权
2. **未来收益**：LST 持有者获得质押收益
3. **赎回路径**：LST 可以兑换回 SUI

## LST 进入 DeFi 的路径

```mermaid
graph TD
    SUI[SUI] -->|质押| LSD[LSD协议]
    LSD -->|铸造| LST[LST Token]
    LST --> DEX[DEX: 交易]
    LST --> LEND[借贷: 抵押品]
    LST --> CDP[CDP: 铸造稳定币]
    LST --> LP[LP: 做市]
```

LST 的二次使用创造了收益叠加：质押收益 + 借贷利息 + LP 手续费。但这不是免费的——每增加一层使用，就增加了一层风险耦合。

## Rebasing vs Non-rebasing 的 DeFi 兼容性

两种模式在与 DeFi 协议集成时表现不同：

| 维度           | Rebasing                       | Non-rebasing                   |
| -------------- | ------------------------------ | ------------------------------ |
| DEX LP 池     | 需要特殊处理余额变化           | 标准代币行为                   |
| 借贷抵押品     | 需要定期更新估值               | 按份额计算即可                 |
| 合约复杂度     | 集成方需理解升值机制           | 集成更简单                     |
| 用户理解       | 「我的代币数量不变但更值钱了」 | 「我可以通过 claim 获得奖励」 |
| 会计准确性     | 链上自动反映，不易出错         | 需要用户主动 claim             |

**在 Sui 上**：由于 Sui 的对象模型，Rebasing LST 的持有者拥有的对象内容会随协议更新而变化。这对 DEX 池子（共享对象）尤其关键——池子需要正确反映 LST 的升值。

## 完整 Move 实现导读

配套代码位于 `src/10_lsd/code/liquid_staking/`。

模块 **`liquid_staking::liquid_staking`**：

- **`LiquidStakingPool`**：共享对象，持有 `Balance<SUI>`，记录总 LST 供应和兑换率
- **`LST`**：流动性质押代币（owned 对象）
- **`AdminCap`**：管理员权限，用于设置验证者集合

阅读顺序：
1. 先读 `LiquidStakingPool` 结构定义，理解字段含义
2. 跟 `stake` 函数：SUI 进 → LST 出
3. 跟 `unstake` 函数：LST 进 → SUI 出
4. 读 `exchange_rate` 计算逻辑
5. 最后读测试用例 `liquid_staking_test.move` 验证完整生命周期

### 关键不变量

代码应维护以下不变量：

1. **总 SUI 余额 >= 总 LST 供应 × 兑换率**：任何时刻协议都有足够的 SUI 覆盖赎回
2. **兑换率单调递增**：每个 epoch 结算后，兑换率只会增加或不变
3. **LST 只能由协议铸造**：外部无法伪造 LST
