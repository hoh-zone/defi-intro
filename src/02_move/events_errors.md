## 2.4 事件、错误码与链上可观测性

### 为什么事件设计是协议工程的一部分

智能合约的内部状态只有通过链上读取才能查看。事件（Event）是协议向外部世界发出的结构化通知。前端、索引器、监控系统和分析工具都依赖事件来跟踪协议行为。

事件设计不是事后补充——它是协议公共接口的一部分，应该在设计阶段就考虑清楚。

```move
module defi_book::events_demo {
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

    public entry fun deposit(
        pool: &mut Pool,
        coin: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
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
}
```

一个好的事件设计包含：
- **谁**（`user`）做了**什么**（`amount`）
- **操作后的状态**（`new_total`）——避免前端再发一笔读取请求
- **时间戳**（`timestamp_ms`）——便于排序和时间序列分析

### 错误码体系

Move 中用 `u64` 常量定义错误码。错误码的编号应该有系统，方便定位。

```move
module defi_book::error_demo {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;

    const EPoolPaused: u64 = 0;
    const EInsufficientLiquidity: u64 = 1;
    const ESlippageExceeded: u64 = 2;
    const EInvalidAmount: u64 = 3;
    const EUnauthorized: u64 = 4;
    const EDuplicatePosition: u64 = 5;
    const EPositionNotFound: u64 = 6;
    const EInsufficientCollateral: u64 = 7;
    const EBorrowLimitExceeded: u64 = 8;
    const ELiquidationThresholdBreached: u64 = 9;

    public struct Pool has key {
        id: UID,
        reserve: Coin<SUI>,
        paused: bool,
    }

    public entry fun swap(
        pool: &mut Pool,
        coin_in: Coin<SUI>,
        min_out: u64,
        ctx: &mut TxContext,
    ) {
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
}
```

错误码编号建议：
- 0-9：通用错误（暂停、未授权、无效输入）
- 10-19：流动性相关错误
- 20-29：价格/滑点相关错误
- 30-39：清算相关错误
- 100+：协议特定错误

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
