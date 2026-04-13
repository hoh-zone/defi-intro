# 7.3 Sui Object Model 如何改变借贷设计

Sui 的 Object Model 为借贷协议带来了独特的架构优势。本节分析这些优势如何影响设计决策。

## 每个仓位是独立对象

### EVM 的方式

```solidity
// Ethereum: 所有仓位存在全局 mapping 中
mapping(address => uint256) public collateralBalance;
mapping(address => uint256) public borrowBalance;

// 更新仓位状态必须通过共享合约
function borrow(uint256 amount) external {
    borrowBalance[msg.sender] += amount;
    // ...
}
```

```
问题:
  → 所有操作通过同一个合约 → 串行执行
  → 大量用户同时操作 → Gas 战争
  → 仓位数据与其他协议隔离 → 难以组合
```

### Sui 的方式

```move
// 每个仓位是独立对象
public struct DepositReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    collateral_amount: u64,
}

public struct BorrowReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    borrow_amount: u64,
}
```

```
优势:
  → 每个用户的仓位是独立对象
  → 可以直接转移、抵押、用于其他 DeFi 协议
  → 不同的 DepositReceipt 可以在不同交易中并行处理

实际效果:
  Alice 的 DepositReceipt 和 Bob 的 DepositReceipt
  → 完全独立的对象
  → 操作 Alice 的仓位不影响 Bob
```

## 并行清算

```
EVM 上的清算:
  所有清算操作通过同一个合约
  → Gas 拍卖（PGAs）
  → 清算人竞争同一笔交易
  → 网络拥堵时清算延迟

  时间线:
  ─────────────────────────────────→
    Block 1    Block 2    Block 3
    清算A      清算B      清算C    （串行）

Sui 上的并行清算:
  不同用户的仓位是不同对象
  → 不同仓位可以同时清算
  → 不同市场的清算互不阻塞

  时间线:
  ─────────────────────────────────→
    Block 1
    清算A | 清算B | 清算C （并行）
```

### 具体场景

```
Sui 上有两个借贷市场:
  SUI/USDC Market — 100 个需要清算的仓位
  ETH/USDC Market — 50 个需要清算的仓位

EVM: 需要逐个处理 150 个清算交易
Sui: 两个市场的清算可以完全并行
     每个市场内的不同仓位也可以并行（大部分情况）

在价格暴跌时:
  → EVM: 清算积压 → 坏账风险
  → Sui: 并行清算 → 更快恢复系统健康
```

## 独立账户风险隔离

```
EVM 风险模型:
  一个 address 在协议中只有一个综合仓位
  → 所有抵押品和债务混在一起计算
  → 某个不良资产可能拖垮整个仓位

Sui 风险模型:
  每个操作产生独立的 Receipt 对象
  → DepositReceipt 独立追踪每笔存款
  → BorrowReceipt 独立追踪每笔借款
  → 风险隔离更精细

例:
  Alice 有两个 DepositReceipt:
    Receipt #1: 1000 SUI (SUI/USDC 市场)
    Receipt #2: 500 ETH (ETH/USDC 市场)

  如果 SUI 市场出问题:
    → 只影响 Receipt #1
    → Receipt #2 的 ETH 仓位不受影响
```

## 对象能力与组合性

```
DepositReceipt 的 has key, store:
  → key: 是独立对象，有全局唯一 ID
  → store: 可以被其他对象包含，可以转移

组合场景:
  1. DepositReceipt 作为 NFT 展示
     → 前端读取对象信息显示仓位

  2. DepositReceipt 用于 DeFi 组合
     → 将 Receipt 转移到收益聚合器
     → 聚合器代为管理仓位

  3. BorrowReceipt 用于清算
     → 清算人提交 BorrowReceipt + 还款
     → 原子化完成清算

PTB 组合:
  PTB:
    1. 从 DEX swap 获得 USDC
    2. 在借贷协议存入 USDC 作为抵押
    3. 借出 SUI
    4. 在 DEX swap SUI 为更多 USDC

  → 全部在一个原子交易中完成
  → 无需中间状态，无需信任
```

## Shared Object vs Owned Object

```
借贷协议中的对象分类:

Shared Object（共享对象）:
  → Market（借贷市场）
  → 所有人都可以读写
  → 通过 consensus 机制保证一致性
  → 是瓶颈点（同一 Market 的操作需要排序）

Owned Object（拥有对象）:
  → DepositReceipt（存款凭证）
  → BorrowReceipt（借款凭证）
  → 只有所有者可以操作
  → 可以并行处理（不同用户的 Receipt 不冲突）

设计原则:
  尽量减少 Shared Object 的访问
  尽量用 Owned Object 管理用户状态

Market (Shared):
  存款 → 修改 Market + 创建 Receipt (Owned)
  取款 → 锁定 Receipt + 修改 Market

清算 → 修改 Market + 销毁 Receipt
```

## 与 lending_market 代码的对应

```
src/07_lending/code/lending_market/sources/market.move:

Shared Object:
  Market<Collateral, Borrow> — 共享的借贷市场

Owned Object:
  DepositReceipt<C, B> — 用户存款凭证 (key + store)
  BorrowReceipt<C, B>  — 用户借款凭证 (key + store)
  AdminCap<C, B>       — 管理员权限 (key + store)

交互模式:
  supply_collateral(market, coin) → DepositReceipt
  borrow(market, receipt, amount) → (Coin, BorrowReceipt)
  repay(market, receipt, coin)    → 清除债务
  liquidate(market, borrow_receipt, coin, deposit_receipt) → Coin
```

## 总结

```
Sui Object Model 对借贷设计的三个关键改变:

1. 仓位对象化
   → 每个仓位是独立对象
   → 可组合、可转移

2. 并行化
   → 不同用户的操作并行
   → 不同市场独立运行
   → 清算更及时

3. 精细权限
   → Owned Object 只能所有者操作
   → Shared Object 最小化
   → 天然的权限隔离
```
