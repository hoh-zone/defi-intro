# 6.7 DeepBook V3 作为订单簿腿：多出来的对象与 `extended_details`

## 与 AMM 腿的本质区别

- **AMM（Cetus CLMM 等）**：核心状态在 **池对象**；聚合器包装函数主要转发 **`SwapContext` + 池 + Clock**。
- **DeepBook V3**：成交在 **订单簿**；除了池/市场对象外，还常涉及 **DEEP 手续费**、**全局配置**、以及有时必须先写的 **价格点 / 参考池** 等辅助操作。

因此 **`DeepbookV3Router`**（`src/movecall/deepbook_v3.ts`）的 `prepareSwapData` 会读 **路径扩展字段**，再决定 PTB 里 **要不要多插一两个 `moveCall`**。

---

## 代码：从 `FlattenedPath` 读出「要不要先 add_deep_price_point」

下面节选展示 **`extended_details`** 如何进入分支逻辑（字段名以 API 为准，随版本可能调整）：

```53:94:/Users/mac/work/cetus/aggregator/src/movecall/deepbook_v3.ts
  private prepareSwapData(flattenedPath: FlattenedPath) {
    if (flattenedPath.path.publishedAt == null) {
      throw new Error("DeepBook V3 not set publishedAt")
    }

    const path = flattenedPath.path
    const [coinAType, coinBType] = path.direction
      ? [path.from, path.target]
      : [path.target, path.from]

    const amountIn = flattenedPath.isLastUseOfIntermediateToken
      ? Constants.AGGREGATOR_V3_CONFIG.MAX_AMOUNT_IN
      : path.amountIn

    const needAddDeepPricePoint =
      path.extendedDetails?.deepbookv3_need_add_deep_price_point ?? false
    const referencePoolId = path.extendedDetails?.deepbookv3_reference_pool_id
    const referencePoolBaseType =
      path.extendedDetails?.deepbookv3_reference_pool_base_type
    const referencePoolQuoteType =
      path.extendedDetails?.deepbookv3_reference_pool_quote_type

    if (needAddDeepPricePoint) {
      if (!referencePoolId) {
        throw new Error(
          "DeepBook V3: deepbookv3_reference_pool_id is required when deepbookv3_need_add_deep_price_point is true"
        )
      }
      // ...
    }
    // ...
  }
```

**读这段代码应建立的直觉：**

1. **类型参数顺序** 仍由 `direction` 决定，与 Cetus 一节相同；
2. **中间币最后一跳** 同样可能用 `MAX_AMOUNT_IN`；
3. **DeepBook 特有** 的是 `needAddDeepPricePoint` 与 **参考池类型**——缺字段时 **客户端直接抛错**，避免发一笔必失败的 PTB。

`swap` 方法里若 `needAddDeepPricePoint` 为真，会先走 `addDeepPricePoint(...)`，再执行真正的 `swap`（具体 `moveCall` 目标名见源码）。

---

## Move 侧：DeepBook 适配模块里还有什么

在 Cetus 聚合器附带的 Move 骨架中（如 `cetus_aggregator_v2::deepbookv3`），可以看到 **除 swap 外** 还有 **白名单、DEEP 费用金库、是否允许替代支付** 等 **治理与费用模块**——这意味着 **同一笔 swap** 可能还依赖 **`DeepbookV3Config` 共享对象** 与 **`Coin<DEEP>`** 作为参数。TS 适配器里的 `Extends` 可选参数就是为此预留的扩展面。

---

## 网络限制

开源 `DeepbookV3Router` 构造函数里可能对 **非 Mainnet** 直接 `throw`——这与 **DeepBook V3 部署范围** 有关；集成前务必读 **官方网络说明**，勿照搬本书举例地址。

下一节：**API 响应 → `parseRouterResponse` → PTB**。
