# 7.11 Collateral Object 设计

抵押品是借贷协议的安全基础。本节分析如何设计 Collateral Object 来追踪用户的抵押品。

## 抵押品的需求

```
抵押品管理需要追踪:
  → 谁存了多少抵押品
  → 抵押品是否足以覆盖借款
  → 价格变动时是否需要清算
  → 取回抵押品时是否仍然安全
```

## EVM 方式 vs Sui 方式

### EVM: Mapping 追踪

```solidity
// Ethereum: 内部 mapping
mapping(address => uint256) public collateralBalance;

// 查询某人的抵押品
function getCollateral(address user) view returns (uint256) {
    return collateralBalance[user];
}
```

```
局限:
  → 仓位数据锁定在合约中
  → 不能将仓位转让给其他地址
  → 不能将仓位用于其他协议
  → 必须通过合约函数访问
```

### Sui: Object 追踪

```move
public struct DepositReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    collateral_amount: u64,
}
```

```
优势:
  → 独立对象，有自己的 ID
  → 可以转移给其他地址
  → 可以被其他对象包含（组合性）
  → 只需要对象引用就能读取

DepositReceipt 代表:
  → 用户在某个 Market 中的抵押品
  → market_id: 确保只能用于对应市场
  → collateral_amount: 存入的抵押品数量
```

## DepositReceipt 的生命周期

```
创建:
  supply_collateral(market, coin)
  → 创建 DepositReceipt，collateral_amount = coin.value

状态变更:
  liquidate() 调用时:
  → deposit_receipt.collateral_amount -= seized_amount
  → 抵押品被部分没收

销毁:
  withdraw_collateral(market, receipt, ...)
  → 销毁 Receipt，返还剩余抵押品

流转图:
  创建 → [被清算减少] → 销毁
  ↑                         ↓
  supply_collateral    withdraw_collateral
```

## 对象能力分析

```
has key:
  → 是全局唯一的对象
  → 有自己的 UID
  → 可以被 transfer, share, freeze

has store:
  → 可以被其他结构体包含
  → 可以作为 dynamic_field 的值
  → 可以在对象之间转移

组合示例:
  // 将 DepositReceipt 放入金库
  public struct YieldVault has key {
    receipts: vector<DepositReceipt<SUI, USDC>>,
  }

  // 或者使用 dynamic field
  dynamic_field::add(&mut vault.fields, "receipt", receipt);
```

## 抵押品锁定机制

```
Supply Collateral:
  User 的 Coin<C> → Market 的 collateral_vault
  → Coin 被消耗（转入 Balance）
  → 用户获得 DepositReceipt

  market.total_collateral += amount
  collateral_vault += amount（Balance join）

Withdraw Collateral:
  DepositReceipt → 销毁
  → collateral_vault 中取出 Coin<C>
  → 返还给用户

  market.total_collateral -= amount
  collateral_vault -= amount（Balance take）

关键不变量:
  collateral_vault.value >= total_collateral
  → 实际资产 >= 账面记录
  → 确保取款时有钱可以还
```

## 多用户并行

```
场景: Alice 和 Bob 同时存入抵押品

  Alice: supply_collateral(market, 1000 SUI)
  Bob:   supply_collateral(market, 500 SUI)

EVM: 两个交易需要串行执行（都修改同一个 mapping）
Sui:  可以并行执行（创建不同的 Receipt 对象）

  唯一的共享状态是 Market（total_collateral 和 collateral_vault）
  → 但 Sui 的共识机制可以高效处理

更重要的并行优势:
  不同用户的 Receipt 操作互不干扰
  Alice 取款不影响 Bob 的 Receipt
  清算 Alice 不需要处理 Bob 的 Receipt
```

## 总结

```
Collateral Object 设计要点:
  DepositReceipt 作为独立对象追踪每个用户的抵押品
  → 记录 market_id 和 collateral_amount
  → 支持转移、组合、并行操作

Sui 对象模型的优势:
  → 天然的仓位隔离
  → DeFi 组合性
  → 并行友好
```
