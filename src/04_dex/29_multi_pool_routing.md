# 4.29 多池路由 Swap

当用户想交易 A→C 但没有直接的 A/C 池，或者直接池的滑点太大时，需要通过多个池路由来获得更好的价格。

## 路由的动机

```
用户想交易 10,000 SUI → ETH

选项 A: 直接 SUI/ETH 池
  池深度浅，滑点 3%

选项 B: SUI → USDC → ETH（经过 USDC 中转）
  SUI/USDC 池深，滑点 0.5%
  USDC/ETH 池深，滑点 0.5%
  总滑点 ≈ 1%
  → 比直接交易更好！

这就是路由的价值
```

## 与聚合器的区别

```
多池路由（本节）:
  在同一个 DEX 内部，寻找最优路径
  例: Cetus DEX 内部的 SUI → USDC → ETH

聚合器（第 6 章）:
  跨越多个 DEX，寻找最优价格
  例: 在 Cetus 和 DeepBook 之间选择

关系: 聚合器使用多池路由作为底层能力
```

## 路径搜索算法

### 池图模型

将所有交易对建模为图：

```
节点 = 代币
边 = 流动性池

    SUI ──── USDC ──── ETH
     │                │
     └──── USDT ──────┘

SUI-USDC 边: SUI/USDC 池
USDC-ETH 边: USDC/ETH 池
SUI-USDT 边: SUI/USDT 池
USDT-ETH 边: USDT/ETH 池
SUI-ETH 边:  SUI/ETH 池
```

### BFS 路径搜索

```
从 SUI 出发，找到 ETH 的所有路径（最多 N 跳）:

路径 1: SUI → ETH (1 跳)
路径 2: SUI → USDC → ETH (2 跳)
路径 3: SUI → USDT → ETH (2 跳)
路径 4: SUI → USDC → USDT → ETH (3 跳) ← 通常不考虑

搜索策略:
  - 限制最大跳数（通常 2-3 跳）
  - 过滤掉明显劣质的路径
  - 对候选路径计算输出量
  - 选择输出量最大的路径
```

### Dijkstra 最优路径

```
将每跳的"成本"定义为价格冲击:
  cost(hop) = -log(output_amount / input_amount)

总成本 = sum of costs for all hops
最优路径 = 最小总成本的路径

优势: 保证找到最优路径
劣势: 计算量比 BFS 大
```

## 输出量计算

### 单路径输出

```
路径: SUI → USDC → ETH

步骤 1: SUI → USDC
  input = 10,000 SUI
  output_1 = amount_out(10000, reserve_sui, reserve_usdc, fee)

步骤 2: USDC → ETH
  input = output_1
  output_2 = amount_out(output_1, reserve_usdc, reserve_eth, fee)

最终输出: output_2 ETH
```

### 多路径拆分

当单路径的最优选择仍然滑点较大时，可以将交易拆分到多个路径：

```
总交易: 10,000 SUI → ETH

拆分方案:
  路径 A (SUI → ETH 直接): 3,000 SUI
  路径 B (SUI → USDC → ETH): 7,000 SUI

路径 A 输出: 3,000 × (1 - 1%) = 2,970 等值 ETH
路径 B 输出: 7,000 × (1 - 0.5%) × (1 - 0.5%) = 6,930 等值 ETH

总输出: 9,900 等值 ETH
对比直连: 10,000 × (1 - 3%) = 9,700 等值 ETH

拆分路由比直连多获得 200 等值 ETH
```

### 最优拆分比

```
设两条路径的价格冲击函数为:
  路径 A: impact_a(x) = x / (reserve_a + x)
  路径 B: impact_b(y) = y / (reserve_b + y)

其中 x + y = total_input

最优化问题:
  最大化: output_a(x) + output_b(total_input - x)
  等价于: 最小化总价格冲击

一阶条件:
  impact_a'(x) = impact_b'(total_input - x)
  → 在两条路径的边际价格冲击相等时达到最优
```

## Sui PTB 实现

```move
// 多跳路由的 PTB 实现
// 注意：这是一个 PTB 的概念示意，不是实际代码

// PTB 步骤:
// 1. 分割输入代币
let (portion_a, portion_b) = coin::split(input, 3000, ctx);

// 2. 路径 A: 直接 Swap
let eth_a = pool_sui_eth.swap_a_to_b(portion_a, 0, ctx);

// 3. 路径 B: 两跳 Swap
let usdc = pool_sui_usdc.swap_a_to_b(portion_b, 0, ctx);
let eth_b = pool_usdc_eth.swap_a_to_b(usdc, 0, ctx);

// 4. 合并输出
coin::join(&mut eth_a, eth_b);
// eth_a 现在包含所有 ETH 输出
```

### PTB 的原子性保证

```
关键优势: 整个路由在一个原子交易中完成

如果路径 B 的第二步失败:
  → 路径 A 也自动回滚
  → 用户不会持有中间代币（如 USDC）

在非原子系统中:
  → 路径 A 成功但路径 B 失败
  → 用户可能持有不想要的中间代币
  → 需要手动处理（额外 Gas）
```

## 路由性能考虑

```
计算复杂度:
  BFS 路径搜索: O(V + E)，V=代币数，E=池数
  单路径输出计算: O(hops)
  多路径优化: O(paths × iterations)

实际约束:
  - 最多 2-3 跳（更多跳的 Gas 成本不值得）
  - 最多 3-5 条并行路径
  - 需要在 100ms 内完成计算（前端 UX 要求）

链上 vs 链下:
  路径搜索在链下完成（前端或后端服务）
  执行在链上（通过 PTB）
  → 计算成本不在链上，不消耗 Gas
```

## 路由优化实战

```
检查清单:
  1. 是否有直连池？滑点如何？
  2. 是否有通过主流币（USDC/USDT）中转的路径？
  3. 中转池的深度是否足够？
  4. 多路径拆分是否能改善总输出？
  5. 手续费 × 跳数是否可接受？

经验法则:
  - 小额交易（< $1K）: 直连即可
  - 中额交易（$1K-$50K）: 检查 1-2 跳路径
  - 大额交易（> $50K）: 多路径拆分 + 多跳路由
  - 稳定币互换: 检查 StableSwap 池是否有更优价格
```
