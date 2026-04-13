# 6.4 DexRouter 接口与路径模型：从 JSON 到 `moveCall`

## `DexRouter`：协议适配器的「统一插头」

在 Cetus 开源 TS 里，每一种 DEX（或同一协议的不同版本）写一个类，实现同一接口 **`DexRouter.swap`**。接口形状（摘自 `src/movecall/index.ts`）可以概括为：

```typescript
export interface DexRouter {
  swap(
    txb: Transaction,
    flattenedPath: FlattenedPath,
    swapContext: TransactionObjectArgument,
    _extends?: Extends
  ): void
}
```

含义：

- **`txb`**：正在构建的 **整笔** PTB，所有腿共享；
- **`flattenedPath`**：**已展开为单跳** 的路径片段（池 id、方向、数量、`published_at` 等）；
- **`swapContext`**：上一节里 **`new_swap_context`** 得到的 **上下文对象**；
- **`Extends`**（可选）：例如 DeepBook 需要的 **DEEP 手续费币**、Pyth 价格对象等 **跨腿共享的额外输入**。

这样 **聚合器主合约** 不必写死「第 3 跳一定是 Cetus」——新增协议时，加 **适配器类 + 报价引擎支持** 即可。

---

## `Path`：链下一跳长什么样

报价 API 解析后（逻辑见开源 `src/api.ts`），一跳通常包含：

| 字段 | 用途 |
|------|------|
| `id` | 池 / 市场 / 注册表对象 ID |
| `from` / `target` | 输入、输出 **Move 类型字符串** |
| `direction` | 池内方向（与 CLMM 的 A→B 定义绑定） |
| `amount_in` / `amount_out` | 链下求解器给出的 **计划量** |
| `published_at` | 本跳应调用的 **包地址**（升级后池可能绑定新包） |
| `provider` | 选用哪个 `DexRouter` 实现 |
| `extended_details` | 协议私有扩展（DeepBook 常见） |

**关键点**：`published_at` 不是装饰字段——PTB 里的 `target` 是  
`{published_at}::模块::函数`，填错会直接 **找不到函数** 或 **类型不匹配 abort**。

---

## `FlattenedPath`：为什么要「再包一层」

单跳路径之外，客户端往往还带 **编排提示**，例如：

- **`isLastUseOfIntermediateToken`**：这一跳是不是 **中间币的最后一跳**？

当中间币在多跳之间传递时，链下估算的 `amount_in` 与链上舍入可能差几个 wei。开源实现里常见策略是：在 **最后一跳** 把 `amount_in` 换成 **极大常量 `MAX_AMOUNT_IN`**，语义是「把当前上下文里能用的输入全部吃掉」，避免 **因估算误差导致剩余非零而 abort**。

这不是「数学最优」本身，而是 **工程上让 PTB 可执行** 的技巧；读源码时看到 `MAX_AMOUNT_IN` 不要困惑。

---

## 与教学 Move 的对应关系

本书 `router_tutorial::SwapContext` 用 `pending_in` / `out_acc` 两个 `Balance` 表达 **尚未用完的输入** 与 **已累积的输出**。真实主网路由的内部字段更多，但 **「上下文在腿之间传递、最后 `confirm` 校验」** 的节奏一致。

---

## 小结

1. **DexRouter** = 把 **FlattenedPath** 编译成 **一条 `moveCall`**；  
2. **`published_at` + type args + 参数顺序** 错一个就整笔失败；  
3. **`MAX_AMOUNT_IN`** 是处理 **中间币舍入** 的常见手段。

下一节：**Cetus CLMM** 的 `CetusRouter` 如何把这一切接到 **`{pkg}::cetus::swap`**。
