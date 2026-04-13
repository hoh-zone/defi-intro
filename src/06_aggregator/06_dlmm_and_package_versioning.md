# 6.6 DLMM、多模块与包版本

## 为什么单独讲 DLMM

**DLMM（离散流动性 / Bin 模型）** 与 CLMM 的 **报价与换跳逻辑** 不同，但 **对聚合器而言接口形状相似**：仍是一跳 `swap`，仍要带 `SwapContext`、池 ID、方向与类型参数。

在 Cetus 开源仓库中，**DLMM** 由独立适配器（如 `CetusDlmmRouter`，见 `src/movecall/cetus_dlmm.ts`）实现 **同一套 `DexRouter`**。教学意义是：**聚合器的主干是接口与数据模型，而不是某一种曲线**。

与 CLMM 一节类似，`executeSwapContract` 最终落到 **模块名不同** 的 `moveCall`——此处为 **`cetus_dlmm::swap`**，且参数里 **多一个 `versioned` 对象**（DLMM 部署常需额外版本句柄）：

```96:111:/Users/mac/work/cetus/aggregator/src/movecall/cetus_dlmm.ts
    const args = [
      swapContext,
      txb.object(this.globalConfig),
      txb.object(swapData.poolId),
      txb.object(this.partner),
      txb.pure.bool(swapData.direction),
      txb.pure.u64(swapData.amountIn),
      txb.object(this.versioned),
      txb.object(SUI_CLOCK_OBJECT_ID),
    ]

    txb.moveCall({
      target: `${swapData.publishedAt}::cetus_dlmm::swap`,
      typeArguments: [swapData.coinAType, swapData.coinBType],
      arguments: args,
    })
```

对比 6.5 节 **`::cetus::swap`**：参数个数与 **共享对象集合** 不同——这正是 **「同一接口、不同适配器」** 要处理的事情。

## `published_at` 与扩展包

Sui 上合约 **可升级**；池对象可能绑定 **不同代的包**。路由数据里带 `published_at`，是为了在 PTB 中调用 **与池一致** 的模块版本。

此外，团队有时会把 **扩展能力** 拆到 **extend / extend2** 等命名包（开源工具函数里可见 `aggregator_v2_extend` 等 key）。集成者要区分：

- **聚合器自身包**（`router::*`）；
- **各 DEX 池子所属包**（`cetus::*`、`dlmm::*` 等）；
- **可选扩展包**（能力插件、兼容层）。

## 工具函数里的 `aggregator_v2` 与 `new_swap_context_v2`（再区分一次）

开源仓库的 `utils/config.ts` / `aggregator-config.ts` 里可能出现 **`getAggregatorV2PublishedAt`** 一类方法：这里的 **V2** 通常指 **聚合器 Move 包族**（如映射 key `aggregator_v2`）的 **发布地址**，用于客户端选择 **调用哪一套路由合约**。

而链上的 **`router::new_swap_context_v2`** 是 **同一套路由合约内部的入口变体**（例如增加 `max_amount_in` 校验）。二者都与「业务产品叫 V2」无必然一一对应，阅读源码时建议 **以函数注释与 Move ABI 为准**。

## 环境差异

部分适配器在开源代码里 **仅支持主网** 或对环境做分支（常见于基础设施依赖差异）。本书不展开具体 `if (env === Mainnet)`，只提醒：**测试网集成前读 README 与 CI 配置**，勿假设全环境可用。

下一节讲 **DeepBook V3** 作为 **订单簿腿** 与 AMM 的差异。
