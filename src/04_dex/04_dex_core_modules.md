# 4.4 一个 DEX 的核心模块

在深入实现之前，先建立 DEX 的模块化架构认知。无论哪种类型的 DEX，核心模块是相同的。

## 模块架构

```
┌─────────────────────────────────────────────────┐
│                  DEX 架构                        │
│                                                 │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  │
│  │   Pool     │  │  LP Acct  │  │ Swap Eng  │  │
│  │  流动性池  │  │  LP 会计  │  │  交易引擎  │  │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  │
│        │              │              │         │
│  ┌─────┴──────────────┴──────────────┴─────┐  │
│  │              Fee System 费用系统          │  │
│  └───────────────────┬─────────────────────┘  │
│                      │                         │
│  ┌───────────────────┴─────────────────────┐  │
│  │              Oracle 价格来源              │  │
│  └─────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## Pool（流动性池）

流动性池是 DEX 的核心数据结构，存储交易所需的代币储备。

### 基本结构

```move
// 最简池结构
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    balance_a: Balance<A>,  // 代币 A 的储备
    balance_b: Balance<B>,  // 代币 B 的储备
    reserve_a: u64,         // 代币 A 的追踪储备量
    reserve_b: u64,         // 代币 B 的追踪储备量
    fee_bps: u64,           // 手续费（基点）
}
```

### 池的定价功能

池通过两种代币的储备比例来确定价格：

```
价格 = reserve_b / reserve_a

例：SUI/USDC 池
  reserve_a (SUI) = 1,000
  reserve_b (USDC) = 2,000
  价格 = 2,000 / 1,000 = 2 USDC/SUI
```

### 不同 DEX 类型的池差异

| DEX 类型   | 池结构                        | 定价方式       |
| ---------- | ----------------------------- | -------------- |
| CPMM       | 两种代币余额                  | x·y=k 恒定乘积 |
| CLMM       | 两种代币 + Tick 状态          | 区间内恒定乘积 |
| DLMM       | 多个 Bin，每个 Bin 存两种代币 | 离散价格桶     |
| StableSwap | 两种稳定币余额                | 稳定曲线       |
| Orderbook  | 挂单列表                      | 买卖匹配       |

## LP Accounting（LP 会计）

LP 会计追踪每个流动性提供者的份额。

### 份额计算

```
首次添加流动性：
  shares = sqrt(amount_a × amount_b)

后续添加流动性：
  shares_a = amount_a × total_shares / reserve_a
  shares_b = amount_b × total_shares / reserve_b
  shares = min(shares_a, shares_b)

提取流动性：
  amount_a = shares × reserve_a / total_shares
  amount_b = shares × reserve_b / total_shares
```

### LP Token 实现

在 Sui 中，LP Token 是独立的对象：

```move
public struct LP<phantom A, phantom B> has key, store {
    id: UID,
    pool_id: ID,   // 所属池的 ID
    shares: u64,   // 持有的份额
}
```

LP Token 是 `key + store` 能力，意味着它可以被转移、存储在其他对象中。

## Swap Engine（交易引擎）

交易引擎根据池的储备量计算交易输出。

### 基本流程

```
输入：
  input_amount, reserve_in, reserve_out, fee_bps

计算：
  1. 扣除手续费：amount_in_with_fee = input × (10000 - fee)
  2. 计算输出：output = amount_in_with_fee × reserve_out
                 / (reserve_in × 10000 + amount_in_with_fee)
  3. 更新储备：reserve_in += input, reserve_out -= output

输出：
  output_amount
```

### 滑点保护

交易者指定最小输出量（min_output），如果实际输出低于此值，交易失败：

```move
assert!(output_amount >= min_output, EInsufficientOutput);
```

## Fee System（费用系统）

手续费是 LP 收入的来源，也是协议可持续运营的基础。

### 费用层级

```
交易手续费（如 0.3%）
  │
  ├── LP Fee（如 0.25%）→ 分配给所有 LP
  │
  └── Protocol Fee（如 0.05%）→ 分配给协议金库
```

### 费用参数设计

| 交易对类型 | 建议总费率 | LP/协议分配 |
| ---------- | ---------- | ----------- |
| 稳定币对   | 0.01-0.05% | 80/20       |
| 主流币对   | 0.05-0.3%  | 80/20       |
| 山寨币对   | 0.3-1%     | 70/30       |
| 长尾资产   | 1-3%       | 60/40       |

## Oracle（价格来源）

DEX 的价格是链上最可靠的资产价格来源之一。其他协议（借贷、CDP、衍生品）都依赖 DEX 输出的价格。

### 价格输出方式

```move
// 即时价格
public fun price<A, B>(pool: &Pool<A, B>): u64 {
    (reserve_b as u128) * SCALE / (reserve_a as u128)
}

// TWAP（时间加权平均价格）
public fun twap<A, B>(pool: &Pool<A, B>, window_ms: u64): u64 {
    // 累计价格差 / 时间窗口
}
```

> 价格的安全性在第 5 章和第 22 章详细讨论。

## 模块间的数据流

```
用户交易请求
     ↓
Swap Engine ← 读取 reserve_a, reserve_b (Pool)
     ↓
计算 output_amount
     ↓
Fee System ← 扣除手续费
     ↓
更新 Pool（reserve_a += input, reserve_b -= output）
     ↓
LP Accounting ← 手续费加入池中（增加 LP 份额价值）
     ↓
Oracle ← 输出更新后的价格
     ↓
返回交易结果给用户
```

后续各节将逐步实现这些模块。从 4.5 节开始，我们将从零构建一个完整的 DEX。
