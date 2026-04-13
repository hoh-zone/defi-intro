# 15.5 英式拍卖：竞价与价格发现

## 从荷兰式到英式

荷兰式拍卖是"从高到低"——价格在降，买家等合适的时机出手。

英式拍卖（English Auction）恰好相反：**从低到高**——买家们不断加价，最后出价最高的人赢得拍品。

这是最常见的拍卖形式：苏富比、佳士得的拍卖会，eBay 的竞价，都是英式拍卖。

## 核心规则

1. 拍卖方设定 **保留价**（reserve price）：最低可接受出价
2. 拍卖方设定 **最小加价**（min bid increment）：每次出价至少比前一次高多少
3. 买家依次出价，每次必须满足 `new_bid >= current_highest_bid + min_bid_increment`
4. 拍卖时间结束后，**最高出价者**赢得拍品，支付其出价金额
5. 其他出价者可以取回自己的出价

## 数学模型

### 出价约束

```
bid_0 >= reserve_price
bid_n >= bid_{n-1} + min_bid_increment   (n >= 1)
```

当前最高出价者不能再次出价（不能自己加价）。

### 数值验证

参数：`reserve_price = 1 SUI`，`min_bid_increment = 0.5 SUI`

| 轮次 | 出价者 | 出价金额 | 约束检查 | 结果 |
|------|--------|---------|---------|------|
| 0 | Alice | 2.0 SUI | 2.0 >= 1.0 (reserve) | 有效，当前最高 |
| 1 | Bob | 3.0 SUI | 3.0 >= 2.0 + 0.5 | 有效，Bob 成为最高 |
| 2 | Carol | 2.5 SUI | 2.5 < 2.0 + 0.5 | 无效！出价太低 |
| 2 | Carol | 3.5 SUI | 3.5 >= 3.0 + 0.5 | 有效，Carol 成为最高 |
| 3 | Alice | 4.2 SUI | 4.2 < 3.5 + 0.5 | 无效！需要 >= 4.0 |
| 3 | Alice | 5.0 SUI | 5.0 >= 3.5 + 0.5 | 有效，Alice 再次成为最高 |

拍卖结束时，Alice 以 5.0 SUI 赢得代币。Bob 和 Carol 可以取回各自的出价。

## 链上实现的特殊考量

### 1. 出价托管

英式拍卖中，每个出价者需要锁定资金。当有人被超越时，之前的出价者应该能取回资金。

```
contract balance = Alice_bid + Bob_bid + Carol_bid  // 所有出价都锁定在合约中

// 拍卖结束后：
// Alice (winner) 的 5 SUI → 项目方
// Bob 的 3 SUI → 退回 Bob
// Carol 的 3.5 SUI → 退回 Carol
```

### 2. 时间窗口

英式拍卖通常有一个固定的结束时间。有些实现会加"延长"机制：如果在最后几分钟有人出价，拍卖延长，防止"最后一秒出价"（sniping）。

### 3. Gas 效率

每轮竞价都需要一笔链上交易。如果参与人数多、竞价轮次多，Gas 成本会比较高。

## Move 数据结构

```move
public struct EnglishAuctionRound has key {
    id: UID,
    treasury_cap: TreasuryCap<EAUC>,
    state: u8,
    reserve_price: u64,         // 最低起拍价
    min_bid_increment: u64,     // 最小加价幅度
    token_amount: u64,          // 拍卖的代币总量
    start_time: u64,            // 开始时间
    duration_ms: u64,           // 拍卖持续时间
    highest_bid: u64,           // 当前最高出价
    highest_bidder: address,    // 当前最高出价者
    bid_count: u64,             // 总出价次数
    winner_claimed: bool,       // 赢家是否已领取
    deposits: Table<address, u64>,    // 每个出价者的保证金
    payment_collected: Balance<SUI>,  // 合约锁定的总资金
}
```

## 完整生命周期

```
1. Admin  → start_auction()        CREATED → ACTIVE
2. Alice  → bid(2 SUI)             首次出价，满足保留价
3. Bob    → bid(3 SUI)             超过 Alice 的 2 + 0.5
4. Carol  → bid(5 SUI)             超过 Bob 的 3 + 0.5
5. Admin  → end_auction()          ACTIVE → ENDED（时间到）
6. Carol  → claim()                赢家领取代币
7. Alice  → withdraw_losing_bid()  退回 2 SUI
8. Bob    → withdraw_losing_bid()  退回 3 SUI
9. Admin  → withdraw_winning_payment()  收取 Carol 的 5 SUI
```

## 荷兰式 vs 英式拍卖

| 维度 | 荷兰式拍卖 | 英式拍卖 |
|------|-----------|---------|
| 价格方向 | 从高到低 | 从低到高 |
| 成交价 | 第一个出价时的价格 | 最后一个出价的价格 |
| 策略 | 等待 vs 抢先（时间博弈） | 加价 vs 放弃（价格博弈） |
| Bot 防御 | 好（需要判断价格合理性） | 一般（Bot 可以自动加价） |
| 信息透明 | 当前价格公开 | 所有出价公开 |
| 适用场景 | 价格未知的新项目 | 稀缺资产、NFT、确定有需求的项目 |
| Gas 成本 | 低（每个买家一笔交易） | 高（多轮竞价多笔交易） |
| 资金效率 | 买家一次性支付 | 所有出价者的资金都被锁定 |

### 选择建议

- **新项目、价格不确定** → 荷兰式拍卖：让市场发现价格
- **热门项目、确定有需求** → 英式拍卖：最大化项目方收入
- **社区发售、价格已确定** → 固定价格：简单直接
