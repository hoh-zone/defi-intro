# 6.5 Cetus CLMM 作为一跳：`CetusRouter` 与链上 `swap`

## 这一节在解决什么问题

聚合器 **不负责重算 CLMM 的 tick 数学**——那是 `cetusclmm::pool` 的事。聚合器负责的是：

1. 从报价 JSON 里读出 **池对象 id、方向、类型、本跳包地址**；
2. 在 PTB 里，把 **`SwapContext`**、**全局配置**、**partner**、**池**、**Clock** 按模块要求 **排进 `moveCall`**；
3. 多跳时重复上述过程，直到路径走完。

Cetus 开源里，CLMM 腿由 **`CetusRouter`**（`src/movecall/cetus.ts`）实现 `DexRouter.swap`。

---

## TypeScript：一次 `swap` 的 `moveCall` 长什么样

`executeSwapContract` 把扁平路径拆成 `coinAType` / `coinBType` / `direction` / `amountIn`，然后调用：

```83:109:/Users/mac/work/cetus/aggregator/src/movecall/cetus.ts
  private executeSwapContract(
    txb: Transaction,
    swapData: {
      coinAType: string
      coinBType: string
      direction: boolean
      amountIn: string
      publishedAt: string
      poolId: string
    },
    swapContext: TransactionObjectArgument
  ) {
    const args = [
      swapContext,
      txb.object(this.globalConfig),
      txb.object(swapData.poolId),
      txb.object(this.partner),
      txb.pure.bool(swapData.direction),
      txb.pure.u64(swapData.amountIn),
      txb.object(SUI_CLOCK_OBJECT_ID),
    ]

    txb.moveCall({
      target: `${swapData.publishedAt}::cetus::swap`,
      typeArguments: [swapData.coinAType, swapData.coinBType],
      arguments: args,
    })
  }
```

请对照读三遍：

1. **第一个参数永远是 `swapContext`**——与 6.3 节一致，DEX 包装函数从上下文里 **扣入金、记入出金**（具体以链上模块为准）；  
2. **`globalConfig` / `partner`** 是 Cetus 协议级共享对象，地址在 `CetusRouter` 构造函数里按 **Mainnet/Testnet** 切换；  
3. **`publishedAt`** 来自路径，不是聚合器写死的 **Cetus 核心包**——因为链上可能存在 **多版本聚合器适配模块** 并存；  
4. **`typeArguments`** 必须是池子真实的 **两币类型顺序** 与 `direction` 组合后的结果（`prepareSwapData` 里用 `direction ? [from,target] : [target,from]`）。

---

## Move 侧：公开仓库里的「形状」与本书关系

Cetus 聚合器仓库里的 Move 有时以 **`cetus_aggregator_v2::cetus`** 或 **`cetus_aggregator_simple::cetus`** 等模块名出现，函数名也可能是 `swap_a2b` / `swap_b2a` 等 **更语义化** 的入口；而 TS 侧 V3 路由统一走 **`::cetus::swap`** 这一 **聚合器包装层**，内部再去调 CLMM 池。

因此你在书里会看到两套名字：

- **`cetusclmm::pool::...`**：CLMM 核心池逻辑（第 4 章）；  
- **`{aggregator_pkg}::cetus::swap`**：给聚合器用的 **薄封装**，参数里带 **`SwapContext`**。

若只打开 `cetus-aggregator-v2/mainnet/sources/cetus.move` 看到 **`abort 0` 占位**，那是因为 **可编译骨架** 与 **生产闭源/未同步** 的常见发布策略；**以 TS 实际调用的 `target` 与链上验证过的 ABI 为准**。

---

## Flash：精确输出路径（进阶）

同一文件还提供 **`flash_swap_fixed_output` + `repay_flash_swap_fixed_output`**：先按 **固定输出量** 从池子「借」流动性，再在后续腿凑齐 **还款**，用于 **多协议组合时锁定中间价**。阅读时抓住 **借—还配对** 即可，不必在第一遍就啃完所有参数。

```113:138:/Users/mac/work/cetus/aggregator/src/movecall/cetus.ts
    const [flashReceipt, repayAmount] = txb.moveCall({
      target: `${path.publishedAt}::cetus::flash_swap_fixed_output`,
      typeArguments: [coinAType, coinBType],
      arguments: args,
    })
```

---

## 小结

| 层次 | 你应记住的一句话 |
|------|------------------|
| 数学 | CLMM 曲线在 **池模块** |
| 聚合 | **`CetusRouter`** 只做 **PTB 编排** |
| 参数 | **`swapContext` 打头、`published_at` 决定包、`typeArguments` 必须与池一致** |

下一节：**DLMM** 与 **多 `published_at`**。
