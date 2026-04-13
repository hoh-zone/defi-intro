# 6.3 链上 Router 与 SwapContext：TS 怎么调、Move 里长什么样

## 为什么需要 SwapContext

多跳 swap 时，中间资产在 PTB 里像接力棒一样传递。聚合器必须在链上持有一个 **可共享、可校验** 的状态，把三件事钉死：

1. **这笔成交对应哪次询价**（`quote_id`，防前端偷换参数）；
2. **用户能接受的输出下限**（`amount_out_limit` / `min_out`，滑点）；
3. **可选：输入硬上限**（`max_amount_in`，防多授权、防 UI 作恶）。

因此链上会有 **`router::new_swap_context`**，返回一个 **上下文对象**；每一跳 DEX 的包装函数（例如 `{pkg}::cetus::swap`）都接收这个对象，在内部 **扣输入、加输出**（或等价逻辑），最后 **`router::confirm_swap`** 一次性校验并交付。

下面分两层看：**客户端 TS 真实长什么样**，以及 **本书配套的教学 Move 如何把结构「落地」**。

---

## 一、TypeScript：一次 `newSwapContext` 在 PTB 里写了什么

Cetus 开源 `src/movecall/router.ts` 中，`newSwapContext` 把参数打成 `moveCall`，目标为 **`{publishedAt}::router::new_swap_context`**，类型参数为 `[fromCoinType, targetCoinType]`：

```55:89:/Users/mac/work/cetus/aggregator/src/movecall/router.ts
export function newSwapContext(
  params: SwapContext,
  txb: Transaction
): TransactionObjectArgument {
  const {
    quoteID,
    fromCoinType,
    targetCoinType,
    expectAmountOut,
    amountOutLimit,
    inputCoin,
    feeRate,
    feeRecipient,
    aggregatorPublishedAt,
    packages,
  } = params

  const publishedAt = getAggregatorPublishedAt(packages, aggregatorPublishedAt)

  const args = [
    txb.pure.string(quoteID),
    txb.pure.u64(expectAmountOut.toString()),
    txb.pure.u64(amountOutLimit.toString()),
    inputCoin,
    txb.pure.u32(Number(feeRate.toString())),
    txb.pure.address(feeRecipient),
  ]

  const swap_context = txb.moveCall({
    target: `${publishedAt}::router::new_swap_context`,
    typeArguments: [fromCoinType, targetCoinType],
    arguments: args,
  }) as TransactionObjectArgument
  return swap_context
}
```

**读代码时抓住三点：**

- **`publishedAt`** 优先来自 API 返回的 `packages` map（支持多版本路由包），而不是写死常量；
- **纯参数与对象参数混排**：`quote_id`、期望/限额输出、费率、收款人是纯量；**输入 `Coin` 是对象**；
- 返回值 **`swap_context`** 会作为后续每一跳 DEX 的第一个（或关键）参数传下去。

`newSwapContextV2` 则在参数列表里 **多塞一个 `maxAmountIn`**，对应链上 **`router::new_swap_context_v2`**，在 **构造阶段** 就要求输入币数量不超过上限：

```101:137:/Users/mac/work/cetus/aggregator/src/movecall/router.ts
export function newSwapContextV2(
  params: SwapContextV2,
  txb: Transaction
): TransactionObjectArgument {
  // ...
  const args = [
    txb.pure.string(quoteID),
    txb.pure.u64(maxAmountIn.toString()),
    txb.pure.u64(expectAmountOut.toString()),
    txb.pure.u64(amountOutLimit.toString()),
    inputCoin,
    txb.pure.u32(Number(feeRate.toString())),
    txb.pure.address(feeRecipient),
  ]

  const swap_context = txb.moveCall({
    target: `${publishedAt}::router::new_swap_context_v2`,
    typeArguments: [fromCoinType, targetCoinType],
    arguments: args,
  }) as TransactionObjectArgument
  return swap_context
}
```

> **再次提醒**：这里的「v2」是 **SwapContext 构造入口的版本**，不是「整本书只讲聚合器第二代产品」的意思。

收尾阶段，同一文件用 **`confirm_swap`** 把目标币从上下文里解出来：

```147:163:/Users/mac/work/cetus/aggregator/src/movecall/router.ts
export function confirmSwap(
  params: ConfirmSwapContext,
  txb: Transaction
): TransactionObjectArgument {
  const { swapContext, targetCoinType, aggregatorPublishedAt, packages } = params

  const publishedAt = getAggregatorPublishedAt(packages, aggregatorPublishedAt)

  const targetCoin = txb.moveCall({
    target: `${publishedAt}::router::confirm_swap`,
    typeArguments: [targetCoinType],
    arguments: [swapContext],
  }) as TransactionObjectArgument
  return targetCoin
}
```

另外还有 `take_balance`、`transfer_balance`、`transfer_or_destroy_coin` 等，用来处理 **余额形态**、找零与转账，对应 PTB **后半段** 的「把钱交干净」。

---

## 二、教学 Move：把「上下文里有什么」写成可编译的最小模型

Cetus 主网路由包的 **完整 Move 源码未必在公开聚合器仓库里**（或仅为占位）；为了在书里仍能 **动手编译、对照字段**，本书在 `06_aggregator/code/aggregator_router_tutorial/` 提供了一个 **缩小版** `SwapContext`：**记住报价 id、min_out、可选 max_in、输入余额与累积输出**，并提供 `record_leg_output` / `confirm_swap`。

核心形状如下（节选，完整见源码）：

```19:70:src/06_aggregator/code/aggregator_router_tutorial/sources/router_tutorial.move
public struct SwapContext<phantom CoinIn, phantom CoinOut> has key, store {
    id: UID,
    quote_id: String,
    min_out: u64,
    max_in: Option<u64>,
    pending_in: Balance<CoinIn>,
    out_acc: Balance<CoinOut>,
}

public fun new_swap_context<CoinIn, CoinOut>(
    quote_id: String,
    min_out: u64,
    coin_in: Coin<CoinIn>,
    ctx: &mut TxContext,
): SwapContext<CoinIn, CoinOut> {
    SwapContext {
        id: object::new(ctx),
        quote_id,
        min_out,
        max_in: option::none(),
        pending_in: coin::into_balance(coin_in),
        out_acc: balance::zero(),
    }
}

public fun new_swap_context_v2<CoinIn, CoinOut>(
    quote_id: String,
    max_in: u64,
    min_out: u64,
    coin_in: Coin<CoinIn>,
    ctx: &mut TxContext,
): SwapContext<CoinIn, CoinOut> {
    assert!(coin::value(&coin_in) <= max_in, EMaxInExceeded);
    SwapContext {
        id: object::new(ctx),
        quote_id,
        min_out,
        max_in: option::some(max_in),
        pending_in: coin::into_balance(coin_in),
        out_acc: balance::zero(),
    }
}
```

```72:102:src/06_aggregator/code/aggregator_router_tutorial/sources/router_tutorial.move
public fun record_leg_output<CoinIn, CoinOut>(
    sc: &mut SwapContext<CoinIn, CoinOut>,
    out_coin: Coin<CoinOut>,
) {
    balance::join(&mut sc.out_acc, coin::into_balance(out_coin));
}

public fun confirm_swap<CoinIn, CoinOut>(
    sc: SwapContext<CoinIn, CoinOut>,
    ctx: &mut TxContext,
): (Coin<CoinIn>, Coin<CoinOut>) {
    let SwapContext { id, quote_id: _, min_out, max_in: _, pending_in, out_acc } = sc;
    object::delete(id);
    assert!(balance::value(&out_acc) >= min_out, EBelowMinOut);
    (coin::from_balance(pending_in, ctx), coin::from_balance(out_acc, ctx))
}
```

**它和主网真实合约的差别（必读）：**

- 真实路由会内嵌 **协议费、事件、与 Cetus/DeepBook 等模块的授权关系**；教学版只保留 **「有限状态 + assert」**；
- 真实 DEX 腿往往 **直接操作 `SwapContext` 内部字段**，而不是单独 `record_leg_output`；这里拆成显式函数只为 **读者能看懂数据流**。

构建示例：

```bash
cd src/06_aggregator/code/aggregator_router_tutorial
sui move build
```

---

## 三、小结：先上下文、再腿、再 confirm

| 阶段 | 链上含义 |
|------|----------|
| `new_swap_context*` | 吃进用户 `Coin`，建立上下文与约束 |
| 各 `DexRouter.swap`（下一节） | 按路径追加多跳调用，消耗/产生中间币 |
| `confirm_swap` / transfer* | 校验 min_out，把目标币交给用户 |

下一节讲 **DexRouter** 如何把 **API 的一跳路径** 变成 **`moveCall`**。
