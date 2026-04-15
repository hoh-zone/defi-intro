# 6.8 链下报价 API 与 PTB 组装：把 JSON 变成可签名交易

## 响应里必须保留的字段

开源 `src/api.ts` 中的 `parseRouterResponse` 把 HTTP JSON 转成 **`RouterDataV3`**。下面这段展示了 **`packages` map** 与 **`paths`** 是如何落到 **强类型对象** 上的（节选）：

```24:59:/Users/mac/work/cetus/aggregator/src/api.ts
function parseRouterResponse(data: any, byAmountIn: boolean): RouterDataV3 {
  let packages = new Map<string, string>()
  if (data.packages) {
    if (data.packages instanceof Map) {
      packages = data.packages
    } else if (typeof data.packages === "object") {
      Object.entries(data.packages).forEach(([key, value]) => {
        packages.set(key, value as string)
      })
    }
  }

  return {
    quoteID: data.request_id || "",
    amountIn: new BN(data.amount_in.toString()),
    amountOut: new BN(data.amount_out.toString()),
    byAmountIn,
    insufficientLiquidity: false,
    deviationRatio: data.deviation_ratio,
    packages,
    paths: data.paths.map((path: any) => ({
      id: path.id,
      direction: path.direction,
      provider: path.provider,
      from: path.from,
      target: path.target,
      feeRate: path.fee_rate,
      amountIn: path.amount_in.toString(),
      amountOut: path.amount_out.toString(),
      version: path.version,
      publishedAt: path.published_at,
      extendedDetails: path.extended_details,
    })),
  }
}
```

**集成时请记住：**

- **`quoteID`** 必须原样喂给 `new_swap_context` 的 `quote_id` 参数（与链上校验联动）；
- **`packages`** 决定 **`getAggregatorPublishedAt`** 解析出的 **`publishedAt`**，影响 **所有** `router::*` 调用的包地址；
- **`publishedAt`（每跳）** 决定 **该跳 DEX 包装模块** 的包地址，与 `packages` 里的聚合器包 **不是同一个概念**。

---

## 从询价到签名的推荐顺序

1. **POST 询价** → 检查业务字段（流动性不足、偏差过大则直接 return）；
2. **`new Transaction()`** → `newSwapContext` / `newSwapContextV2`；
3. **按 `paths` 顺序** 调各 `DexRouter.swap`（或引擎提供的统一 `build` 函数）；
4. **`confirmSwap`** →（可选）`transferOrDestroyCoin`；
5. **钱包 `signAndExecuteTransaction`**。

---

## 本书仓库里的代码放在哪

| 内容                              | 路径                                                 |
| --------------------------------- | ---------------------------------------------------- |
| **可编译的 SwapContext 教学模块** | `src/06_aggregator/code/aggregator_router_tutorial/` |
| 旧版 TS 小示例（可能过时）        | `src/06_aggregator/code/aggregator_ts/`              |
| **完整生产级 SDK**                | 以你克隆的 Cetus `aggregator` 开源仓库为准           |

```bash
# 教学 Move 包
cd src/06_aggregator/code/aggregator_router_tutorial && sui move build
```

下一节：**拆单、滑点与 Gas**。
