# 7.26 Isolated Market 模型

Isolated Market 将每种资产对独立管理，风险互不影响。

## 核心概念

```
Isolated Market:
  每个交易对是独立的市场
  → Market<SUI, USDC> 独立于 Market<ETH, USDC>
  → 一个市场出问题不影响其他市场
```

## lending_market 就是 Isolated 模型

```move
public struct Market<phantom Collateral, phantom Borrow> has key {
    id: UID,
    collateral_vault: Balance<Collateral>,
    borrow_vault: Balance<Borrow>,
    // ...
}
```

```
泛型参数决定独立性:
  Market<SUI, USDC>: 只处理 SUI 做抵押借 USDC
  Market<ETH, USDC>: 只处理 ETH 做抵押借 USDC
  → 两个市场完全独立，不同的 Shared Object
```

## 优势

```
1. 风险隔离
   SUI/USDC 市场出问题 → ETH/USDC 不受影响

2. 简单安全
   每个市场逻辑简单，容易审计和测试

3. 灵活参数
   每个市场独立的利率和风险参数

4. 并行友好
   不同市场是不同 Shared Object → Sui 可并行处理
```

## 劣势

```
1. 资本效率低
   不能组合多种抵押品

2. 流动性碎片化
   USDC 分散在多个市场

3. 用户体验
   需要分别操作不同市场
```

## 代表协议

```
Euler V1 / Silo:
  每种资产独立子市场

Scallop (Sui):
  类似 Isolated 模型 + 统一用户界面
```

## 总结

```
Isolated Market: 风险隔离最好，资本效率最低，实现最简单
适用: 新资产、高风险资产、简单协议
```
