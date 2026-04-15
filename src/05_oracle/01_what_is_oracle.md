# 5.1 什么是预言机：为什么 DeFi 需要链外数据

## 链上的世界是封闭的

区块链是一个确定性状态机——给定相同的输入，所有节点必须产出相同的结果。这意味着区块链无法主动获取外部信息。

```
链上可知的：
  ✓ 账户余额
  ✓ 合约状态
  ✓ 交易历史

链上不可知的：
  ✗ ETH 的美元价格
  ✗ 今天旧金山的天气
  ✗ 昨晚 NBA 比赛结果
  ✗ 一个真正的随机数
```

预言机（Oracle）就是解决这个问题的基础设施：**将链外数据安全地传递到链上**。

## DeFi 为什么依赖预言机

```
借贷协议：
  "这 100 ETH 抵押品值多少 USDC？" → 需要价格预言机
  "该不该清算这个仓位？" → 需要实时价格

DEX：
  "LP 仓位应该收取多少手续费？" → 需要报价参考

衍生品：
  "永续合约的标记价格是多少？" → 需要预言机价格
  "资金费率该收多少？" → 需要指数价格

保险：
  "稳定币是否脱锚？" → 需要价格预言机
  "今天是否下雨？" → 需要天气预言机

NFT / 游戏：
  "抽奖谁是赢家？" → 需要随机数预言机
```

## 预言机的信任问题

使用预言机就是**信任某人（或某组人）提供正确的数据**。不同的预言机有不同的信任模型：

```
信任问题清单：

1. 数据从哪来？
   - 单一数据源 vs 多数据源聚合
   - 交易所 API vs 链上流动性池

2. 谁在维护？
   - 中心化运营方 vs 去中心化验证者网络
   - 质押保证诚实性 vs 无质押

3. 多久更新？
   - 每个区块 vs 按需 vs 定期
   - 更新延迟多少？

4. 数据怎么验证？
   - 签名验证 vs 共识验证 vs 无验证
   - 置信区间（confidence interval）

5. 出错了怎么办？
   - 有无 fallback 机制
   - 能否紧急切换
   - 谁承担损失
```

## 三种"价格"的区别

```
市场价格（Market Price）：
  Binance 上 ETH/USDC 的最新成交价
  → 最"真实"的价格，但不在链上

协议价格（Protocol Price）：
  协议内部使用的价格，可能来自预言机、AMM 或管理员设置
  → 链上可用，但可能有延迟或偏差

价格事实（Price Fact）：
  预言机发布者签名的价格声明
  → 不可篡改，但"签名人说价格是 X"不等于"价格真的是 X"
```

### 用 Move 表达三种价格

```move
module oracle::price_types;

use sui::clock::Clock;

public struct MarketPrice has store {
    price: u64,
    timestamp_ms: u64,
    source: String,
    confidence: u64,
}

public struct ProtocolPrice has store {
    price: u64,
    last_update_ms: u64,
    max_staleness_ms: u64,
    source_id: u8,
}

public struct PriceFact has store {
    price: u64,
    publish_time_ms: u64,
    publisher: address,
    signature: vector<u8>,
    ema_price: u64,
}

public fun is_stale(protocol: &ProtocolPrice, clock: &Clock): bool {
    clock.timestamp_ms() > protocol.last_update_ms + protocol.max_staleness_ms
}

public fun deviation(p1: u64, p2: u64): u64 {
    if (p1 > p2) { (p1 - p2) * 10000 / p2 } else { (p2 - p1) * 10000 / p1 }
}
```

## 预言机的冷启动问题

一个新链或新协议上线时面临：

```
问题 1：主流预言机可能还没支持这条链
  → Sui 在 2023 年之前只有有限的预言机选择

问题 2：即使预言机存在，数据 feeds 可能不完整
  → 只有主流交易对有价格，长尾代币没有

问题 3：AMM 池的流动性太低，无法产生可靠价格
  → TWAP 在低流动性池中容易被操纵

解决方案：
  - 使用管理员设置价格（中心化，但可启动）
  - 接入多个预言机，互相校验
  - 设计插槽接口，方便后续升级
  - 使用安全的价格读取函数（5.9 节）
```

## 风险分析

| 风险       | 描述                                     |
| ---------- | ---------------------------------------- |
| 过度信任   | 盲目相信预言机数据，不做任何验证         |
| 单点故障   | 只用一个预言机，如果它挂了协议就停摆     |
| 延迟风险   | 预言机更新慢，价格在剧烈波动时严重偏离   |
| 数据源操纵 | 攻击者操纵预言机的数据源（如交易所价格） |
