# 4.1 交易为什么是 DeFi 的入口

## 三个不可替代的功能

### 价格发现

在没有 DEX 的世界里，链上资产没有价格。一个 NFT 值多少 USDC？一个新发的代币值多少 SUI？没有交易，就没有答案。

DEX 通过交易行为产生价格。AMM 通过池内比例推导，订单簿通过买卖撮合。无论哪种方式，交易是价格的来源。

### 资产转换

DeFi 用户经常需要在不同代币之间切换：用 USDC 买 SUI、把 LP Token 换成稳定币、把奖励代币换成 ETH。没有 DEX，这些操作都需要通过中心化交易所完成——而 CeFi 的 KYC、提币限制、宕机风险恰恰是 DeFi 要解决的问题。

### 退出通道

这是最容易被忽视的功能。当你参与一个借贷协议，你的资产被锁定在池子里。当你想退出时，你需要把借出资产卖掉换回基础代币。如果 DEX 没有流动性，你就无法退出。

**2022 年 Celsius 事件的核心问题之一就是：用户想退出，但 DEX 流动性枯竭，无法出售资产。**

## Sui 上的特殊性

在以太坊上，交易操作的是合约存储中的数字。在 Sui 上，交易操作的是对象。

```move
public fun swap_exact_input<TIn, TOut>(
    pool: &mut Pool<TIn, TOut>,
    input_coin: Coin<TIn>,
    ctx: &mut TxContext,
): Coin<TOut> {
    let input_amount = coin::value(&input_coin);
    let output_amount = calculate_output(input_amount, pool);
    coin::take(&mut pool.coin_b, output_amount, ctx)
}
```

注意这个函数签名：
- `pool: &mut Pool<TIn, TOut>` — 共享对象，任何人都能访问
- `input_coin: Coin<TIn>` — 用户的代币对象，作为参数传入
- 返回 `Coin<TOut>` — 新铸造的输出代币对象

在 Sui 上，资产转移就是对象转移。不存在"approve"这个概念——你把对象传给函数，函数处理完返回新对象。这让资产流更加清晰。
