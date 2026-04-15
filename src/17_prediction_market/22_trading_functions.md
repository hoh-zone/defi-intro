# 17.22 Move 实现交易函数

本节把前两节的 buy/sell 逻辑整合，讨论 API 设计、LMSR 与 Position 的关系、以及如何在 PTB 中组合调用。

## 公开 API 总览

```
交易函数:
  buy_yes(market, coin_in, shares, clock, ctx)   → void（退款自动转回）
  buy_no(market, coin_in, shares, clock, ctx)    → void
  sell_yes(market, shares, clock, ctx)           → Coin<T>
  sell_no(market, shares, clock, ctx)            → Coin<T>

条件代币函数:
  split(market, pos, coin_in, ctx)               → void（更新 Position）
  merge(market, pos, amount, ctx)                → void（退款转回）

头寸管理:
  new_position(market, ctx)                      → Position

查询函数:
  q_yes(market), q_no(market), b(market)         → u64
  vault_amount(market)                           → u64
  position_yes(pos), position_no(pos)            → u64
```

## LMSR 交易 vs CTF 操作

```
这两组操作的目的不同:

LMSR 交易（buy/sell）:
  → 改变做市状态 q_yes / q_no
  → 支付/收取由成本函数决定的金额
  → 不直接改变用户的 Position

CTF 操作（split/merge）:
  → 不改变做市状态
  → 按 1:1 存入/取出抵押
  → 直接改变用户的 Position.yes / Position.no

它们可以独立使用:
  场景 A: 只用 LMSR — 用户通过 buy/sell 参与，不需要 Position
  场景 B: 只用 CTF  — 用户只做 split/merge，然后场外交易 Position
  场景 C: 组合使用 — 用户 buy + split 在同一 PTB 中
```

## 在 PTB 中组合：「买入并记入头寸」

```
Sui 的 Programmable Transaction Block (PTB) 允许原子性组合:

PTB {
  // Step 1: 买 YES（LMSR 层面）
  let refund_coin = buy_yes(market, coin_200, 100, clock, ctx);

  // Step 2: 拆分一些抵押到头寸（CTF 层面）
  split(market, position, coin_100, ctx);
}

组合效果:
  → LMSR 状态: q_yes += 100
  → Position: yes += 100, no += 100（来自 split）
  → vault: += buy_cost + 100（LMSR 收入 + split 抵押）

如果要让 buy 直接更新 Position:
  → 修改 buy_internal 增加 &mut Position 参数
  → pos.yes += shares（或 pos.no += shares）
  → 这是产品层设计选择，教学版保持两层解耦
```

## 完整交易生命周期示例

```
Alice 参与 "SUI > $5 by Q4 2025?" 市场

PTB 1 — 建立头寸:
  new_position(&market, ctx)     → Position { yes: 0, no: 0 }

PTB 2 — 拆分 + 卖 NO:
  split(market, pos, coin_500, ctx)   → pos { yes: 500, no: 500 }
  // 等价于「我看好 YES，不要 NO」
  // 场外把 NO 转让给看空的 Bob

PTB 3 — 通过 LMSR 加仓 YES:
  buy_yes(market, coin_200, 100, clock, ctx)
  // q_yes += 100, vault += buy_cost

PTB 4 — 行情变化，减仓:
  sell_yes(market, 50, clock, ctx)
  // q_yes -= 50, 获得 refund

PTB 5 — 结算后领奖:
  claim(market, pos, ctx)
  // 如果 YES 赢: 获得 pos.yes × 1 USDC
  // pos.yes = 0, pos.no = 0
```

## 事件（Events）驱动链下

```
每次交易发出 Traded 事件:

  Traded {
      market_id: ID,      // 哪个市场
      side_is_yes: bool,  // 买的是 YES 还是 NO
      shares: u64,        // 买了多少份
      collateral_paid: u64, // 付了多少钱（含手续费）
  }

链下索引器可以:
  1. 重建完整的 q_yes / q_no 历史 → 画价格走势图
  2. 计算每个用户的已实现 PnL
  3. 检测异常交易（大单、高频）

前端显示:
  当前隐含胜率 = p_YES = exp(q_yes/b) / (exp(q_yes/b) + exp(q_no/b))
  → 前端只需要读 q_yes, q_no, b 三个值就能计算
```

## API 设计权衡

| 设计点        | 当前选择        | 替代方案         | 讨论                                   |
| ------------- | --------------- | ---------------- | -------------------------------------- |
| buy 参数      | 指定 shares     | 指定最大支付     | 指定 shares 更精确，但用户需要预估费用 |
| sell 返回     | Coin<T>         | void（自动转账） | 返回 Coin 更灵活，可在 PTB 中组合      |
| buy 退款      | public_transfer | 返回剩余 Coin    | public_transfer 简单但不可组合         |
| Position 更新 | 不更新          | buy 时同步更新   | 解耦更清晰，组合在 PTB 层              |

## Gas 成本估算

```
每次 buy/sell 的主要 Gas 消耗:

  cost_state × 2:     ~300 次 u128 运算
  coin::split:         1 次对象操作
  balance::join:       1 次对象操作
  event::emit:         1 次事件
  状态更新:            2 次 u64 写入

总估算: ~3000-5000 Gas 单位
  → Sui 上约 0.001-0.003 SUI
  → 比 DEX swap（~2000 Gas 单位）稍贵
  → 主要开销在 LMSR 的 exp/ln 计算
```

## 自检

1. 如果在同一个 PTB 中先 `buy_yes(100)` 再 `sell_yes(100)`，净效果是什么？（答：手续费损失 + Gas 费）
2. 设计题：如何修改 API 使 `buy_yes` 变成「指定最大支付 → 计算最多能买多少份」？
