# 11.2 闪电贷攻击与价格操纵

## 闪电贷不是攻击

闪电贷是一个工具，不是攻击本身。它做的事情很简单：让没有资本的人也能执行需要大量资金的交易。

闪电贷的攻击性在于：**它将"需要大量资本"的攻击变成了"零资本"的攻击。**

## 单区块攻击 vs 跨区块攻击

### 单区块攻击（Same-block Attack）

所有操作在一笔交易内完成。攻击者不需要持有任何资金。

```
交易内：
  借入 → 操纵价格 → 利用漏洞 → 偿还 → 保留利润
```

防御：使用 TWAP（跨多个区块的平均价格）。

### 跨区块攻击（Multi-block Attack）

攻击跨越多个区块。攻击者需要持有资金至少一个区块。

```
区块 1: 操纵价格（如大量存入/取出影响池子状态）
区块 2: 利用被扭曲的状态获利
区块 3: 恢复操作
```

防御：价格更新延迟、状态变化冷却期。

## 常见利用场景

### 场景 1：三明治攻击（Sandwich Attack）

```move
module sandwich {
    public fun attack(
        pool: &mut Pool<TokenA, TokenB>,
        victim_amount: u64,
        ctx: &mut TxContext,
    ) {
        let front_run = swap_a_to_b(pool, victim_amount * 2, ctx);
        let victim_tx = swap_a_to_b(pool, victim_amount, ctx);
        let back_run = swap_b_to_a(pool, front_run_amount, ctx);
    }
}
```

攻击者在 victim 交易前买入（推高价格），victim 以更高价格成交，攻击者再卖出获利。

防御：使用限价单而不是市价单、设置滑点保护、使用 MEV 保护机制。

### 场景 2：操纵 LP 定价

当协议使用 DEX LP Token 的价格来评估抵押品时，攻击者可以通过大量交易扭曲 LP Token 的价值。

## 防御清单

| 防御措施 | 针对的攻击 | 实现方式 |
|----------|-----------|----------|
| TWAP | 单区块操纵 | 累积价格 / 时间窗口 |
| 延迟机制 | 快速攻击 | 操作后等待 N 个区块 |
| 交易量限制 | 大额操纵 | 单笔交易量上限 |
| 多源价格 | 单一来源操纵 | 中位数或加权平均 |
| 闪电贷检测 | 零成本攻击 | 检测同区块内的价格异常变化 |
