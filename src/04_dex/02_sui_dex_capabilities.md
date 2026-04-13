# 4.2 Sui 对 DEX 的关键能力

Sui 的技术架构为 DEX 提供了独特的优势。理解这些能力，是设计 Sui 原生 DEX 的前提。

## Object Model（对象模型）

Sui 的一切都是对象（Object）。每个对象有唯一的 ID、所有者、类型。这对 DEX 意味着：

### 仓位即对象

```
EVM 模型：
  合约存储 mapping(address => Position)
  所有仓位存储在合约中，每次操作需要读写整个合约状态

Sui 模型：
  每个仓位是一个独立的 Object
  Position { id, collateral, debt, ... }
  操作只涉及特定对象，其他对象不受影响
```

对 DEX 的具体好处：

1. **LP Position 可以是独立的 NFT 对象**
   - 每个 LP 的仓位独立存在，不需要全局 mapping
   - 转移 LP 仓位 = 转移一个对象
   - 在 CLMM 中，不同价格区间的仓位是独立对象

2. **Pool 是 Shared Object**
   - 所有交易者访问同一个池对象
   - Sui 的共识机制保证 shared object 的一致性

3. **资产隔离**
   - 每个池的资金是独立的 Balance 对象
   - 一个池的安全问题不会影响其他池

## 并行执行（Parallel Execution）

Sui 的最大技术亮点是交易并行执行。这对 DEX 极其重要：

```
传统链（串行执行）：
  TX1: Swap SUI/USDC  ────→
  TX2: Swap ETH/USDC  ──────→  （等待 TX1 完成）
  TX3: Swap SUI/USDC  ────────────→  （等待 TX2 完成）
  总耗时: TX1 + TX2 + TX3

Sui（并行执行，不同交易对）：
  TX1: Swap SUI/USDC  ────→
  TX2: Swap ETH/USDC  ────→  （并行！不同 shared object）
  TX3: Swap SUI/USDC  ──────────→  （等 TX1，同一 shared object）
  总耗时: TX1 + TX3（TX2 与 TX1 并行）
```

### 并行性对 DEX 的影响

| 场景 | 串行链 | Sui 并行 |
|------|--------|---------|
| 10 个不同交易对的 Swap | 10x 延迟 | ~1x 延迟 |
| 相同交易对的 10 笔 Swap | 10x 延迟 | 10x 延迟（同一 shared object） |
| 添加流动性 + 不同对 Swap | 2x 延迟 | 1x 延迟（并行） |

关键洞察：**Sui 上的 DEX 天然支持不同交易对的并行交易**。这意味着：
- 交易对越多，Sui 的吞吐量优势越大
- Gas 战争只在同一交易对中发生，不同交易对互不影响

## Shared Object 与拥有对象

Sui 区分两种对象类型，对 DEX 设计有直接影响：

```
拥有对象（Owned Object）：
  - 只有所有者可以操作
  - 不需要共识，即时确认
  - 例：用户的 LP Token、钱包中的 Coin

Shared Object：
  - 任何人都可以操作
  - 需要共识排序
  - 例：流动性池、全局状态
```

DEX 中对象的分类：

| DEX 组件 | 对象类型 | 原因 |
|---------|---------|------|
| Pool（池） | Shared | 任何人都可以 Swap |
| LP Position | Owned | 只有 LP 可以管理自己的仓位 |
| Admin Cap | Owned | 只有管理员可以修改参数 |
| Coin | Owned | 只有持有者可以使用 |
| Treasury | Shared | 需要全局访问 |

## 低延迟交易

Sui 的交易确认速度在 400ms 以下，远快于大多数 L1：

| 链 | 出块时间 | 确认时间 |
|----|---------|---------|
| Ethereum | 12s | 12-120s |
| Solana | 400ms | 400ms-5s |
| Sui | ~300ms | 400ms-1s |

低延迟对 DEX 的意义：
- **套利更快**：价格偏差被更快修正
- **清算更快**：借贷协议的清算可以更及时
- **用户体验更好**：Swap 几乎即时确认
- **降低 MEV**：更短的确认窗口意味着更少的 MEV 机会

## PTB（可编程交易块）

PTB（Programmable Transaction Block）允许在一个交易中组合多个操作。对 DEX 来说，这意味着原子化的复杂交易：

```
传统方式（多笔交易）：
  TX1: 在 DEX A 中 Swap SUI → USDC
  TX2: 在 DEX B 中 Swap USDC → ETH
  风险：TX1 成功但 TX2 失败 → 用户持有 USDC 而非 ETH

PTB（一个交易）：
  PTB:
    1. Swap SUI → USDC（在 DEX A）
    2. Swap USDC → ETH（在 DEX B）
  原子性：要么全部成功，要么全部回滚
```

PTB 对 DEX 的高级应用：
- **跨 DEX 套利**：在一个 PTB 中完成套利循环
- **闪电贷 + Swap**：借入 → Swap → 获利 → 归还，全部原子化
- **多跳路由**：SUI → USDC → ETH → 目标代币，一步完成
- **限价单模拟**：条件判断 + Swap，实现类似限价单的功能

## 小结：Sui DEX 设计思维

```
传统 DEX 思维：
  "如何在 EVM 的限制下实现 AMM？"

Sui DEX 思维：
  "如何利用 Object Model、并行执行、PTB 来设计更好的 DEX？"

关键差异：
  1. 用独立对象代替全局 mapping → 更好的隔离和并行
  2. 用 Shared Object 实现池 → 任何人可交互
  3. 用 PTB 实现原子化复杂操作 → 无需中间合约
  4. 低延迟 → 更好的交易体验
  5. 并行执行 → 不同交易对互不干扰
```
