## 2.4 事件、错误码与链上可观测性

### 为什么事件设计是协议工程的一部分

智能合约的内部状态只有通过链上读取才能查看。事件（Event）是协议向外部世界发出的结构化通知。前端、索引器、监控系统和分析工具都依赖事件来跟踪协议行为。

事件设计不是事后补充——它是协议公共接口的一部分，应该在设计阶段就考虑清楚。

```move
module defi_book::events_demo;

use sui::coin::{Self, Coin};
use sui::sui::SUI;

public struct Pool has key {
    id: UID,
    reserve: Coin<SUI>,
    total_deposits: u64,
    total_withdrawals: u64,
}

public struct DepositEvent has copy, drop {
    pool_id: ID,
    user: address,
    amount: u64,
    new_total: u64,
    timestamp_ms: u64,
}

public struct WithdrawalEvent has copy, drop {
    pool_id: ID,
    user: address,
    amount: u64,
    fee: u64,
    new_total: u64,
}

public struct PausedEvent has copy, drop {
    pool_id: ID,
    admin: address,
}

public entry fun deposit(pool: &mut Pool, coin: Coin<SUI>, ctx: &mut TxContext) {
    let amount = coin.value(&coin);
    coin::join(&mut pool.reserve, coin);
    pool.total_deposits = pool.total_deposits + amount;

    event::emit(DepositEvent {
        pool_id: object::id(pool),
        user: ctx.sender(),
        amount,
        new_total: pool.total_deposits,
        timestamp_ms: tx_context::timestamp_ms(ctx),
    });
}
```

一个好的事件设计包含：

- **谁**（`user`）做了**什么**（`amount`）
- **操作后的状态**（`new_total`）——避免前端再发一笔读取请求
- **时间戳**（`timestamp_ms`）——便于排序和时间序列分析

### 错误：`#[error]` 与可读 abort

推荐用 **`#[error]`** 标注 **`vector<u8>`** 常量（短英文消息），在浏览器与 CLI 中更易读；`assert!(cond, EName)` 与 `abort EName` 均使用该常量。**不要**再为新代码引入仅数字的 `u64` 错误码。

```move
module defi_book::error_demo;

use sui::coin::{Self, Coin};
use sui::sui::SUI;

#[error]
const EPoolPaused: vector<u8> = b"Pool Paused";
#[error]
const EInsufficientLiquidity: vector<u8> = b"Insufficient Liquidity";
#[error]
const ESlippageExceeded: vector<u8> = b"Slippage Exceeded";
#[error]
const EInvalidAmount: vector<u8> = b"Invalid Amount";
#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EDuplicatePosition: vector<u8> = b"Duplicate Position";
#[error]
const EPositionNotFound: vector<u8> = b"Position Not Found";
#[error]
const EInsufficientCollateral: vector<u8> = b"Insufficient Collateral";
#[error]
const EBorrowLimitExceeded: vector<u8> = b"Borrow Limit Exceeded";
#[error]
const ELiquidationThresholdBreached: vector<u8> = b"Liquidation Threshold Breached";

public struct Pool has key {
    id: UID,
    reserve: Coin<SUI>,
    paused: bool,
}

public entry fun swap(pool: &mut Pool, coin_in: Coin<SUI>, min_out: u64, ctx: &mut TxContext) {
    assert!(!pool.paused, EPoolPaused);
    assert!(coin_in.value(&coin_in) > 0, EInvalidAmount);

    let reserve = pool.reserve.value(&pool.reserve);
    assert!(reserve > min_out, EInsufficientLiquidity);

    let amount_out = calculate_output(coin_in.value(&coin_in), reserve);
    assert!(amount_out >= min_out, ESlippageExceeded);

    execute_swap(pool, coin_in, ctx);
}

fun calculate_output(amount_in: u64, reserve: u64): u64 {
    reserve * amount_in * 9970 / ((reserve + amount_in) * 10000)
}

fun execute_swap(_pool: &mut Pool, _coin: Coin<SUI>, _ctx: &mut TxContext) {}
```

命名建议：错误常量 **`EPascalCase`**，消息与常量含义一致；测试中 `expected_failure` 使用 **`abort_code = module::E…`**，避免魔法数字。

### 链上可观测性

事件和错误码共同构成了协议的**可观测性**。一个设计良好的协议应该让外部观察者仅通过事件流就能完整重建协议状态：

```bash
# 使用 Sui CLI 查询事件
sui client events --module events_demo --function deposit

# 使用 sui-sdk 过滤特定事件
sui client events --filter '{"MoveEventModule": {"module": "events_demo", "package": "0xPACKAGE"}}'
```

前端和监控系统的典型架构：

```
链上事件 → 索引器（如 Sui RPC / custom indexer）→ 数据库 → 前端 / 监控面板
```

> 风险提示：遗漏关键事件是协议设计的常见缺陷。如果你的借贷协议没有在清算时发出事件，外部监控就无法检测到清算行为。如果你的 DEX 没有在费率变更时发出事件，用户无法知道交易条件已经改变。在审计时，事件覆盖度应该是检查清单的一项——每个状态变更函数都应该有对应的事件。
