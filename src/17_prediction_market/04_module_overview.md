# 17.4 协议整体模块图

## 分层（逻辑模块）

```text
                    ┌───────────────────┐
                    │  Market Factory    │  create_market：注入 b、费率、时间窗
                    └─────────┬─────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐
│ Conditional     │  │ LMSR Engine     │  │ Collateral Pool  │
│ Split / Merge   │  │ C(q), ΔC, 价格  │  │ vault + 手续费   │
└────────┬────────┘  └────────┬────────┘  └────────┬─────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              ▼
                    ┌───────────────────┐
                    │ Resolution        │  submit / challenge / finalize
                    └─────────┬─────────┘
                              ▼
                    ┌───────────────────┐
                    │ Claim             │  胜出份额赎回抵押
                    └───────────────────┘
```

## 数据流（一次买 YES）

1. 读取 `Clock`：确认未过 `trading_closes_ms`。
2. 读取当前 \(\mathbf{q}=(q_Y,q_N)\)，计算 \(\Delta C=C(\mathbf{q}')-C(\mathbf{q})\)。
3. 加费：\(\text{fee}=\Delta C\cdot\text{fee\_bps}/10000\)（实现见 `fee_on`）。
4. 用户 `Coin<T>` 入 `vault`；更新 `q_Y`（或 `q_N`）。
5. （若要把「买到的暴露」记入用户头寸，可在同一事务更新 `Position`——教学包将 LMSR 状态与用户 CTF 记账**分开演示**，见 17.14。）

## 与 `pm.move` 的对应表

| 模块概念 | 类型/函数 |
|----------|-----------|
| 共享市场 | `Market<T>`（`key + store`，`public_share_object`） |
| 用户头寸 | `Position { market_id, yes, no }` |
| LMSR | `lse_wad`, `cost_state`, `buy_internal`, `sell_internal` |
| 金库 | `Market.vault` |
| 裁决 | `submit_result`, `challenge_result`, `finalize_result` |
| 赎回 | `claim` |

## 刻意没有写进教学包的东西

- **动态 \(b\)**、**自适应费率**、**链上随机数**、**多市场组合 NegRisk** 等——留给产品与审计迭代；本章只保证**主干正确、可测、可读**。
