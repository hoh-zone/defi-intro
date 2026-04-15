# 4.14 多池设计

一个 DEX 通常需要支持多个交易对。每个交易对是一个独立的流动性池。多池设计涉及池的创建、发现、费率分层等关键架构决策。

## 为什么需要多个池

```
单一池的局限:
  只能交易一对代币（如 SUI/USDC）
  用户想交易 ETH/USDC？需要新的池

实际需求:
  SUI/USDC
  SUI/ETH
  ETH/USDC
  USDC/USDT
  ...
  → 每对代币需要一个独立的池
```

## Factory 模式

### 设计思路

创建池的函数不直接暴露给用户，而是通过工厂模式管理：

```move
// 工厂模式：统一管理所有池的创建
public struct PoolFactory has key {
    id: UID,
    // 记录已创建的池
    pools: VecMap<(type_info::TypeInfo, type_info::TypeInfo), ID>,
}

public fun create_pool<A, B>(
    factory: &mut PoolFactory,
    coin_a: Coin<A>,
    coin_b: Coin<B>,
    fee_bps: u64,
    ctx: &mut TxContext,
) {
    // 确保 A != B
    // 确保此交易对尚未创建
    // 创建池并记录 ID
}
```

### 规范化交易对

```
问题：SUI/USDC 和 USDC/SUI 是同一个交易对吗？

方案：按类型排序，确保 A < B（按类型名排序）
  → SUI/USDC 只有一种表示
  → 避免重复创建
```

## 池注册与发现

用户如何找到他们想交易的池？

### 方法一：链上注册表

```move
// 工厂中维护所有池的映射
pools: VecMap<(TypeInfo, TypeInfo), ID>

// 查询函数
public fun get_pool_id<A, B>(factory: &PoolFactory): Option<ID>
```

### 方法二：链下索引

```
链下服务监听 PoolCreated 事件:
  → 建立数据库: (tokenA, tokenB) → pool_address
  → 前端查询数据库获取池地址
  → 然后直接与池交互

Sui 优势: 事件系统完善，链下索引容易实现
```

## 多费率层级

同一交易对可以有不同费率的池，满足不同需求：

```
SUI/USDC 可能有三个池:
  0.05% 费率池 → 适合大额交易者（低费率）
  0.30% 费率池 → 标准池
  1.00% 费率池 → 适合波动性大的市场

Uniswap V3 和 Cetus 都采用这种多费率设计
```

### 费率层级选择指南

| 费率  | 适用交易对  | LP 收益 | 交易者成本 |
| ----- | ----------- | ------- | ---------- |
| 0.01% | 稳定币      | 低      | 极低       |
| 0.05% | 主流币      | 中低    | 低         |
| 0.30% | 标准币对    | 中      | 标准       |
| 1.00% | 山寨币/长尾 | 高      | 高         |

## Sui 对象模型的多池优势

### 每个池是独立的 Shared Object

```
传统模型:
  所有池在同一个合约中
  操作任何池都需要读写整个合约状态

Sui 对象模型:
  每个池是一个独立的 Shared Object
  操作 SUI/USDC 池不影响 ETH/USDC 池
  → 并行执行

具体影响:
  10 个交易对不同池的 Swap 可以并行处理
  Gas 战争只在同一池内发生
  一个池的安全问题不影响其他池
```

### 实际架构

```
┌──────────────────────────────────────┐
│         Sui DEX 多池架构              │
│                                      │
│  PoolFactory (Shared Object)         │
│    ├── SUI/USDC Pool (Shared Object) │
│    ├── SUI/ETH Pool (Shared Object)  │
│    ├── ETH/USDC Pool (Shared Object) │
│    └── USDC/USDT Pool (Shared Object)│
│                                      │
│  LP Token A (Owned by LP1)           │
│  LP Token B (Owned by LP2)           │
│  AdminCap (Owned by Admin)           │
└──────────────────────────────────────┘

并行性:
  Swap on SUI/USDC ─┐
  Swap on ETH/USDC ─┤→ 并行执行
  Swap on USDC/USDT─┘
```

## 路由问题

当用户想交易 A→C，但没有直接的 A/C 池时，需要通过中间代币路由：

```
直接交易: SUI → USDC ✅ (有 SUI/USDC 池)
间接路由: SUI → ETH → USDC ✅ (通过两个池)

路由选择:
  路径 1: SUI → USDC (1 跳, 费率 0.3%)
  路径 2: SUI → ETH → USDC (2 跳, 费率 0.3%×2 = 0.6%)

不一定 1 跳最便宜：
  如果 SUI/USDC 池流动性浅，滑点大
  而 SUI/ETH 和 ETH/USDC 池流动性深
  → 2 跳可能总成本更低

→ 路由优化详见 4.29 节
```

## 池的生命周期管理

```
创建 → 添加流动性 → 正常交易 → 可能的暂停 → 可能的升级/迁移

关键管理操作:
  1. 创建池: 任何人或仅管理员
  2. 暂停/恢复: 紧急情况处理
  3. 参数调整: 费率、协议费比例
  4. 池迁移: 合约升级时迁移流动性

在 Sui 中:
  - 暂停通过 paused 标志实现
  - 参数调整通过 AdminCap 控制
  - 池迁移通过 PTB 原子化执行
```
