# 7.6 Move 实现 Supply Pool

本节逐行分析 `sui_savings` 代码包的 Supply Pool 实现。

## SavingsPool 结构体

```move
// code/sui_savings/sources/savings.move

public struct SavingsPool<phantom T> has key {
    id: UID,
    principal: Balance<T>,      // 存入的本金（资产池）
    reward_pool: Balance<T>,    // 奖励池（利息/奖励）
    total_shares: u64,          // 总份额
    interest_rate_bps: u64,     // 利率（基点）
    paused: bool,               // 紧急暂停标志
}
```

```
字段说明:
  principal: 用户的存款本金
  reward_pool: 管理员添加的利息/奖励
  total_shares: 所有用户的份额总和
  interest_rate_bps: 名义利率（实际利息通过 reward_pool 分配）
  paused: 紧急情况可暂停存取

关键设计:
  → has key: 是 Shared Object（所有人可访问）
  → phantom T: 支持任意代币类型
```

## deposit 函数

```move
public fun deposit<T>(
    pool: &mut SavingsPool<T>,
    coin: Coin<T>,
    ctx: &mut TxContext,
): SavingsReceipt<T> {
    assert!(!pool.paused, EPoolPaused);
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);

    // 计算份额
    let shares = if (pool.total_shares == 0) {
        amount                        // 首个存款人: 1:1
    } else {
        amount * pool.total_shares     // 后续存款人: 按汇率
            / balance::value(&pool.principal)
    };
    assert!(shares > 0, EInvalidAmount);  // 防膨胀攻击

    // 更新状态
    pool.total_shares = pool.total_shares + shares;
    balance::join(&mut pool.principal, coin::into_balance(coin));

    // 发出事件
    sui::event::emit(DepositEvent { amount, shares });

    // 创建 Receipt
    SavingsReceipt<T> {
        id: object::new(ctx),
        pool_id: object::id(pool),
        shares,
    }
}
```

```
执行流程:
  1. 检查是否暂停
  2. 验证金额 > 0
  3. 计算份额（首个用户 1:1，后续按汇率）
  4. 验证 shares > 0（防膨胀攻击）
  5. 更新 total_shares
  6. 将代币加入池子
  7. 发出事件
  8. 返回 SavingsReceipt（Owned Object）
```

## withdraw 函数

```move
public fun withdraw<T>(
    pool: &mut SavingsPool<T>,
    receipt: SavingsReceipt<T>,
    ctx: &mut TxContext,
): Coin<T> {
    // 验证 Receipt 属于这个池子
    assert!(object::id(pool) == receipt.pool_id, EInvalidAmount);

    // 按当前汇率计算可取金额
    let principal_value = if (pool.total_shares == 0) {
        receipt.shares
    } else {
        receipt.shares * balance::value(&pool.principal) / pool.total_shares
    };
    assert!(balance::value(&pool.principal) >= principal_value, EInsufficientBalance);

    // 减少总份额
    pool.total_shares = pool.total_shares - receipt.shares;

    // 销毁 Receipt
    let shares = receipt.shares;
    let SavingsReceipt { id, pool_id: _, shares: _ } = receipt;
    id.delete();

    sui::event::emit(WithdrawEvent { amount: principal_value, shares });

    // 返还代币
    coin::take(&mut pool.principal, principal_value, ctx)
}
```

```
执行流程:
  1. 验证 Receipt 的 pool_id 匹配
  2. 按当前汇率计算可取金额
  3. 确保池中有足够余额
  4. 减少总份额
  5. 销毁 Receipt（热土豆模式）
  6. 返还代币

注意:
  → Receipt 消耗后不可恢复
  → 取款金额可能 > 存款金额（因为利息/奖励）
```

## claim_interest 函数

```move
public fun claim_interest<T>(
    pool: &mut SavingsPool<T>,
    receipt: &SavingsReceipt<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(pool.total_shares > 0, EInvalidAmount);

    // 计算用户的份额比例
    let user_share_bps = receipt.shares * 10000 / pool.total_shares;

    // 按比例计算奖励
    let pending_reward = balance::value(&pool.reward_pool)
        * user_share_bps / 10000;
    assert!(pending_reward > 0, EInvalidAmount);

    // 从奖励池取出
    coin::take(&mut pool.reward_pool, pending_reward, ctx)
}
```

```
利息领取逻辑:
  → 按 shares 占 total_shares 的比例分配 reward_pool
  → 不消耗 Receipt（可以多次领取）
  → 简化模型: 管理员手动添加奖励到 reward_pool

生产级模型的区别:
  → 利息自动累积到 principal（通过 exchange_rate 增长）
  → 不需要单独的 reward_pool
  → withdraw 时自动包含利息
```

## AdminCap 治理模式

```move
public struct AdminCap<phantom T> has key, store {
    id: UID,
    pool_id: ID,
}

// 只有 AdminCap 持有者可以调用
public fun add_rewards<T>(
    _cap: &AdminCap<T>,          // ← 需要提供 AdminCap
    pool: &mut SavingsPool<T>,
    reward: Coin<T>,
) {
    balance::join(&mut pool.reward_pool, coin::into_balance(reward));
}
```

```
AdminCap 的设计:
  → 创建池子时同时创建 AdminCap
  → 转移给创建者（transfer::transfer(cap, ctx.sender())）
  → 只有持有者可以调用管理函数

管理函数:
  add_rewards: 添加奖励
  set_interest_rate: 修改利率
  pause / unpause: 紧急暂停/恢复

未来可以转移给多签钱包或 DAO
```

## 完整生命周期示例

```
初始:
  创建 SavingsPool (shared object)
  创建 AdminCap (transfer to creator)

Alice:
  deposit(1000 SUI) → SavingsReceipt { shares: 1000 }
  // pool: 1000 SUI, 1000 shares

Admin:
  add_rewards(50 SUI)
  // pool.principal: 1000 SUI, reward_pool: 50 SUI

Alice:
  claim_interest(&receipt)
  // 获得: 1000/1000 × 50 = 50 SUI

Alice:
  withdraw(receipt) → 1000 SUI
  // 销毁 Receipt，取回本金
```

## 总结

```
sui_savings 展示了 Supply Pool 的核心概念:
  Share Token 记账 — shares 追踪存款份额
  汇率计算 — shares × exchange_rate = 实际价值
  Receipt 模式 — Owned Object 代表存款凭证
  AdminCap 治理 — 管理员控制参数

这是更复杂借贷协议的存款部分基础
```
