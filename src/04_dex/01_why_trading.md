# 4.1 为什么交易是 DeFi 的入口

## 三个不可替代的功能

### 价格发现

在没有 DEX 的世界里，链上资产没有价格。一个 NFT 值多少 USDC？一个新发的代币值多少 SUI？没有交易，就没有答案。

DEX 通过交易行为产生价格。AMM 通过池内比例推导，订单簿通过买卖撮合。无论哪种方式，交易是价格的来源。

### 资产转换

DeFi 用户经常需要在不同代币之间切换：用 USDC 买 SUI、把 LP Token 换成稳定币、把奖励代币换成 ETH。没有 DEX，这些操作都需要通过中心化交易所完成。

### 退出通道

这是最容易被忽视的功能。当你参与一个借贷协议，你的资产被锁定在池子里。当你想退出时，你需要把借出资产卖掉换回基础代币。如果 DEX 没有流动性，你就无法退出。

## Sui 上的特殊性

在以太坊上，交易操作的是合约存储中的数字。在 Sui 上，交易操作的是对象。

```move
public fun swap<TIn, TOut>(
    pool: &mut Pool<TIn, TOut>,
    input: Coin<TIn>,
    ctx: &mut TxContext,
): Coin<TOut> {
    let amount_in = coin::value(&input);
    let amount_out = calculate_output(amount_in, pool);
    coin::merge(&mut pool.coin_a, input);
    coin::take(&mut pool.coin_b, amount_out, ctx)
}
```

在 Sui 上，资产转移就是对象转移。不存在"approve"——你把对象传给函数，函数处理完返回新对象。这让资产流更加清晰。

## 学习路径

本章从最简单的 DEX 类型开始，逐步增加复杂度：

1. **固定汇率**：1:1 兑换，理解最基本的概念
2. **AMM**：用算法定价，理解"池子"和"滑点"
3. **Uniswap V2**：AMM 的经典实现，完整代码
4. **Uniswap V3**：集中流动性，提升资金效率
5. **DLMM**：动态流动性，Cetus 的核心机制
6. **StableSwap**：稳定币对的特殊曲线
7. **Orderbook**：限价单撮合，DeepBook 的实现

每一步都在解决上一步的局限性。理解这个递进过程，比记住每个 DEX 的参数更重要。
