# 7.5 Compound V1→V4：逐代创新分析

## Compound 的演进脉络

Compound 是第一个上线的主流借贷协议。每一代都在解决上一代的架构问题。

```
Compound V1 (2018) → V2 (2019) → V3 (2022) → V4 (2024)
  基础借贷           cToken      单抵押品     Modular
```

## Compound V1：借贷的开端

核心创新：**链上借贷市场**

在 Compound 之前，DeFi 只有 DEX。Compound V1 第一次证明了链上借贷是可行的。

机制：
- 每种代币一个市场（ETH Market, DAI Market, USDC Market...）
- 存款人供应资金，获得利息
- 借款人抵押资产，借出其他资产
- 利率由供需决定（利用率的函数）

V1 的局限：
- 利率模型不够灵活
- 没有代币化的存款凭证
- 清算机制简单

## Compound V2：cToken 与 Comptroller

核心创新：

### 1. cToken（存款代币）

V2 最重要创新：存款被代币化为 cToken。

```
存入 100 DAI → 获得 cDAI（数量 < 100）
随着利息累积：1 cDAI 可以兑换越来越多的 DAI
汇率 = total_supply / total_cToken_supply
```

```move
struct CToken<phantom T> has key, store {
    id: UID,
    underlying: Balance<T>,
    total_supply: u64,
    exchange_rate: u128,
    reserve_factor_bps: u64,
}

public fun exchange_rate<Underlying>(ctoken: &CToken<Underlying>): u128 {
    let total_cash = balance::value(&ctoken.underlying);
    let total_borrows = get_total_borrows();
    ((total_cash + total_borrows) * 1000000000 / (ctoken.total_supply as u128))
}

public fun mint<Underlying>(
    ctoken: &mut CToken<Underlying>,
    underlying: Coin<Underlying>,
) -> u64 {
    let amount = coin::value(&underlying);
    let rate = exchange_rate(ctoken);
    let ctokens = ((amount as u128) * 1000000000 / rate) as u64;
    ctoken.total_supply = ctoken.total_supply + ctokens;
    balance::join(&mut ctoken.underlying, coin::into_balance(underlying));
    ctokens
}

public fun redeem<Underlying>(
    ctoken: &mut CToken<Underlying>,
    ctoken_amount: u64,
    ctx: &mut TxContext,
): Coin<Underlying> {
    let rate = exchange_rate(ctoken);
    let underlying_amount = ((ctoken_amount as u128) * rate / 1000000000) as u64;
    ctoken.total_supply = ctoken.total_supply - ctoken_amount;
    coin::take(&mut ctoken.underlying, underlying_amount, ctx)
}
```

cToken 的意义：
- 存款凭证可以在其他协议中使用（如作为 DEX 的交易对）
- 开启了 DeFi 可组合性的新维度
- 利息通过汇率变化自动累积，不需要 rebase

### 2. Comptroller（风险控制器）

V2 将风险管理从借贷逻辑中独立出来：

```move
struct Comptroller has key {
    id: UID,
    markets: vector<MarketInfo>,
    close_factor_bps: u64,
    liquidation_incentive_bps: u64,
    min_collateral: u64,
    paused: bool,
}

struct MarketInfo has store {
    ctoken_id: ID,
    is_listed: bool,
    collateral_factor_bps: u64,
    borrow_cap: u64,
    supply_cap: u64,
}
```

Comptroller 负责：
- 决定哪些资产可以作为抵押品
- 设置每种资产的抵押因子（Collateral Factor）
- 设置借款和存款上限
- 判断账户是否可以被清算

### 3. COMP 代币与流动性挖矿

Compound V2 引入了 COMP 治理代币，按借款和存款量分配。这开启了 DeFi 的"流动性挖矿"时代。

## Compound V3：单抵押品模型

核心创新：**只使用一种基础资产作为抵押品**

### 为什么退回到单抵押品

V2 的多抵押品模型有一个系统性风险：**关联资产同时下跌时的级联清算**。

V3 的解决方案：
- 每个市场只有一种抵押品（如 USDC 市场用 ETH 做抵押品）
- 借出的资产由市场决定
- 风险隔离更彻底

```
V2 市场：
  抵押品: ETH, WBTC, DAI, UNI, ...
  借出: USDC, DAI, ETH, ...
  → 任何抵押品暴跌都可能影响整个市场

V3 市场（USDC 市场）：
  抺押品: ETH（只有一种）
  借出: USDC, DAI, USDT, ...
  → ETH 暴跌只影响 ETH 抵押的仓位
```

### 其他 V3 改进

- **更低的 Gas**：合约重写，Gas 降低 60%
- **简化的清算**：absorb 机制（坏账直接由协议吸收）
- **奖励代币化**：用 Comet 协议统一管理奖励

## Compound V4：模块化架构

核心创新：**可组合的模块化借贷引擎**

V4 将借贷协议拆分为独立的模块：
- **Rate Module**：利率模型
- **Collateral Module**：抵押品管理
- **Liquidation Module**：清算逻辑
- **Reward Module**：奖励分发
- **Risk Module**：风险参数

每个模块可以独立升级、独立治理。其他协议可以只使用部分模块。

```move
module compound_v4 {
    struct ModuleRegistry has key {
        id: UID,
        rate_module: ID,
        collateral_module: ID,
        liquidation_module: ID,
        reward_module: ID,
        risk_module: ID,
    }
}
```

## Compound 四代创新总结

| 版本 | 年份 | 核心创新 | 行业影响 |
|------|------|----------|----------|
| V1 | 2018 | 链上借贷市场 | DeFi 借贷的开端 |
| V2 | 2019 | cToken + Comptroller + COMP | 存款代币化成为标准 |
| V3 | 2022 | 单抵押品 + absorb 清算 | 风险隔离的新思路 |
| V4 | 2024 | 模块化架构 | 借贷协议成为可组合基础设施 |

## Aave vs Compound 设计哲学对比

| 维度 | Aave | Compound |
|------|------|----------|
| 核心思路 | 功能丰富，持续加新特性 | 架构简洁，每次重构减复杂度 |
| 抵押品模型 | 多抵押品共享市场 | V3 后转向单抵押品 |
| 存款凭证 | aToken（rebase） | cToken（汇率升值） |
| 利率模式 | 固定/浮动可切换 | 纯浮动 |
| 清算方式 | 部分清算 + 激励 | absorb（协议吸收坏账） |
| 治理 | AAVE 代币 | COMP 代币 |
| 创新方向 | 跨链 + 统一流动性 | 模块化 + 可组合性 |
