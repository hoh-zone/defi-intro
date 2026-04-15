# 4.3 Sui DEX 生态概览

Sui 生态已经有多种类型的 DEX，每种选择了不同的技术路线。理解这些协议的差异，是学习 DEX 设计的最佳起点。

## Sui 主要 DEX 一览

| DEX               | 类型        | 特点                            | 交易量级别 |
| ----------------- | ----------- | ------------------------------- | ---------- |
| Cetus             | CLMM        | Sui 最大的 CLMM DEX，集中流动性 | 最高       |
| Turbos Finance    | CLMM        | 高性能集中流动性，多链部署      | 高         |
| FlowX Finance     | Hybrid      | AMM + Orderbook 混合模式        | 中高       |
| Kriya             | AMM + Perps | AMM 交易 + 永续合约             | 中         |
| DeepBook          | Orderbook   | Sui 原生限价单订单簿            | 高         |
| Aftermath Finance | CLMM        | 集中流动性 + 自动复投           | 中         |

## Cetus：CLMM 标杆

Cetus 是 Sui 上 TVL 最大的 DEX，采用 CLMM（Concentrated Liquidity Market Maker）模型。

```
Cetus 的核心特点：
  1. 集中流动性：LP 可以选择价格区间提供流动性
  2. 多费率层级：不同波动性的交易对使用不同的 fee tier
  3. 闪电贷：支持单笔交易内的无抵押借贷
  4. 聚合器：路由到其他 DEX 获取最优价格
```

为什么 Cetus 选择 CLMM 而不是传统 AMM：

- 资本效率：同样 1000 美元，CLMM 可以在目标价格区间提供更深流动性
- LP 灵活性：LP 可以选择自己愿意做市的价格范围
- 更低滑点：在集中的价格区间内，交易者的滑点更小

## Turbos Finance：多链 CLMM

Turbos 与 Cetus 类似，也采用 CLMM 模型，但有多链部署策略。

```
Turbos 的差异化：
  1. 多链部署：不止 Sui，覆盖多个生态
  2. 交易挖矿：提供代币激励吸引流动性
  3. 简化的 LP 体验：降低集中流动性的使用门槛
```

## FlowX Finance：Hybrid 模式

FlowX 选择了混合模式（AMM + Orderbook），这在 Sui 上是独特的定位。

```
Hybrid DEX 的设计思路：
  AMM 模式：
    → 适合小额交易、即时成交
    → 提供基础流动性

  Orderbook 模式：
    → 适合大额交易、精确定价
    → 专业交易者的首选

  两种模式共享流动性：
    → AMM 池的价格成为 Orderbook 的参考价格
    → Orderbook 的挂单成为 AMM 的额外流动性
```

## Kriya：AMM + 衍生品

Kriya 将 AMM 交易与永续合约结合。

```
Kriya 的特点：
  1. 现货 AMM：标准的代币兑换
  2. 永续合约：链上杠杆交易
  3. 统一流动性：现货和衍生品共享部分流动性
```

这种设计的优势是形成生态闭环：用户在 Kriya Swap 后可以直接开杠杆，不需要跨协议操作。

## DeepBook：Sui 原生 Orderbook

DeepBook 是 Sui 上最知名的订单簿 DEX，由 Sui 基金会支持开发。

```
DeepBook 的设计理念：
  1. 纯订单簿：不使用 AMM，完全基于挂单撮合
  2. Maker/Taker 模型：Maker（挂单者）手续费更低
  3. 专业交易：支持限价单、止损单等
  4. 深度集成：被多个 Sui 前端和聚合器集成

Sui 对 Orderbook 的优势：
  - 对象模型：每个订单可以是独立对象
  - 并行执行：不同交易对的撮合可以并行
  - 低延迟：订单匹配速度快
```

## 生态关系图

```
                    Sui DEX 生态
                         │
          ┌──────────────┼──────────────┐
          │              │              │
      CLMM 类        Hybrid 类     Orderbook 类
          │              │              │
    ┌─────┴─────┐    FlowX          DeepBook
    │           │    Finance
  Cetus      Turbos
  Finance    Finance

外部集成：
  聚合器（Cetus Aggregator、Aftermath 等）
    → 搜索最优路径
    → 跨 DEX 拆单
  预言机
    → 使用 DEX 价格作为数据源
    → TWAP 输出给借贷/CDP 协议
```

## 选择框架预览

不同场景应该选择不同类型的 DEX：

| 用户需求               | 推荐 DEX 类型  | Sui 上的选择   |
| ---------------------- | -------------- | -------------- |
| 快速小额 Swap          | AMM / CLMM     | Cetus、Turbos  |
| 大额交易，需要精确价格 | Orderbook      | DeepBook       |
| 稳定币互换             | StableSwap     | Cetus 稳定币池 |
| 提供流动性赚手续费     | CLMM           | Cetus、Turbos  |
| 专业做市               | Orderbook      | DeepBook       |
| 长尾资产交易           | CLMM（宽区间） | Cetus          |
| 杠杆交易               | AMM + Perps    | Kriya          |

> 详细的架构选择框架见 4.30 节。
