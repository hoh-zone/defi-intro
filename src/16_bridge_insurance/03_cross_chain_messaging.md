# 16.3 跨链消息传递与组合性

## 从资产转移到消息传递

锁铸桥只处理资产转移。更强大的跨链桥支持**任意消息传递**（General Message Passing, GMP）：

```
资产转移：锁定 ETH → 铸造 wrapped ETH
消息传递：源链调用目标链合约函数
组合调用：跨链调用链，涉及多条链
```

## 跨链调用的挑战

```
挑战 1：原子性
  源链和目标链无法共享一个原子交易
  → 如果目标链执行失败，源链的状态已经改变
  → 需要回滚机制

挑战 2：排序
  源链发出多个消息，目标链需要按顺序执行
  → 如果乱序执行可能导致状态不一致

挑战 3：超时
  跨链消息可能永远不到达（中继者宕机）
  → 需要超时机制让源链回滚
```

## 跨链消息的 Move 实现

```move
module bridge::cross_chain_messaging;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;
    use sui::clock::Clock;
    use sui::table::{Self, Table};

    #[error]
    const EUnauthorized: vector<u8> = b"Unauthorized";
    #[error]
    const EInvalidProof: vector<u8> = b"Invalid Proof";
    #[error]
    const EAlreadyExecuted: vector<u8> = b"Already Executed";
    #[error]
    const ENotPending: vector<u8> = b"Not Pending";
    #[error]
    const ETimeoutNotReached: vector<u8> = b"Timeout Not Reached";

    public struct MessageId has copy, drop, store {
        source_chain: u64,
        nonce: u64,
    }

    public struct CrossChainMessage has store {
        target_chain: u64,
        target_contract: address,
        payload: vector<u8>,
        timeout_ms: u64,
    }

    public struct MessageStatus has store {
        is_executed: bool,
        is_rolled_back: bool,
    }

    public struct MessageBus has key {
        id: UID,
        nonce_counter: u64,
        pending_messages: Table<MessageId, CrossChainMessage>,
        executed: Table<MessageId, MessageStatus>,
        timeout_buffer_ms: u64,
        admin: address,
    }

    public struct MessageSent has copy, drop {
        msg_id: MessageId,
        target_chain: u64,
        sender: address,
    }

    public struct MessageExecuted has copy, drop {
        msg_id: MessageId,
        executor: address,
        success: bool,
    }

    public struct MessageRolledBack has copy, drop {
        msg_id: MessageId,
        reason: String,
    }

    public fun initialize(
        timeout_buffer_ms: u64,
        ctx: &mut TxContext,
    ) {
        let bus = MessageBus {
            id: object::new(ctx),
            nonce_counter: 0,
            pending_messages: table::new(ctx),
            executed: table::new(ctx),
            timeout_buffer_ms,
            admin: ctx.sender(),
        };
        transfer::share_object(bus);
    }

    public fun send_message(
        bus: &mut MessageBus,
        target_chain: u64,
        target_contract: address,
        payload: vector<u8>,
        timeout_ms: u64,
        clock: &Clock,
    ): MessageId {
        let msg_id = MessageId {
            source_chain: 0,
            nonce: bus.nonce_counter,
        };
        bus.nonce_counter = bus.nonce_counter + 1;
        let msg = CrossChainMessage {
            target_chain,
            target_contract,
            payload,
            timeout_ms: clock.timestamp_ms() + timeout_ms,
        };
        table::add(&mut bus.pending_messages, msg_id, msg);
        event::emit(MessageSent {
            msg_id,
            target_chain,
            sender: ctx.sender(),
        });
        msg_id
    }

    public fun execute_message(
        bus: &mut MessageBus,
        msg_id: MessageId,
        proof: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(&bus.executed, msg_id), EAlreadyExecuted);
        assert!(table::contains(&bus.pending_messages, msg_id), ENotPending);
        let _msg = table::borrow(&bus.pending_messages, msg_id);
        table::add(&mut bus.executed, msg_id, MessageStatus {
            is_executed: true,
            is_rolled_back: false,
        });
        table::remove(&mut bus.pending_messages, msg_id);
        event::emit(MessageExecuted {
            msg_id,
            executor: ctx.sender(),
            success: true,
        });
    }

    public fun rollback(
        bus: &mut MessageBus,
        msg_id: MessageId,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&bus.pending_messages, msg_id), ENotPending);
        let msg = table::borrow(&bus.pending_messages, msg_id);
        assert!(clock.timestamp_ms() > msg.timeout_ms, ETimeoutNotReached);
        table::add(&mut bus.executed, msg_id, MessageStatus {
            is_executed: false,
            is_rolled_back: true,
        });
        table::remove(&mut bus.pending_messages, msg_id);
        event::emit(MessageRolledBack {
            msg_id,
            reason: string::utf8(b"timeout"),
        });
    }

    public fun message_status(
        bus: &MessageBus,
        msg_id: MessageId,
    ): u8 {
        if (table::contains(&bus.executed, msg_id)) {
            let status = table::borrow(&bus.executed, msg_id);
            if (status.is_executed) { 1 } else { 2 }
        } else if (table::contains(&bus.pending_messages, msg_id)) {
            0
        } else {
            3
        }
    }
```

## 跨链组合调用

```
跨链 Flash Loan 示例：

1. 在以太坊发起闪电贷（借 100 ETH）
2. 通过跨链消息将 100 ETH 发送到 Sui
3. 在 Sui 上的 DEX 套利
4. 将利润和本金通过跨链消息发回以太坊
5. 偿还闪电贷

如果步骤 3 失败：
  → 需要将 100 ETH 发回以太坊
  → 如果超时，闪电贷已经过期
  → 资金可能被锁定

这就是跨链组合调用的核心难点：失败处理的复杂度指数增长。
```

## Wormhole 的跨链消息模型

Wormhole 是 Sui 生态的主要跨链消息协议：

```
架构：
  Guardian 网络（19 个节点）→ 观察源链 → 签名确认 → 中继到目标链

消息类型：
  - Transfer：资产转移
  - Contract Call：跨链合约调用
  - Governance：跨链治理消息

Sui 集成：
  Wormhole 在 Sui 上部署了核心合约
  任何 Sui Move 合约可以接收和发送 Wormhole 消息
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 部分执行 | 跨链调用链中间步骤失败，资金卡在中间链 |
| 超时攻击 | 攻击者延迟中继，导致消息超时后利用回滚逻辑 |
| 消息重放 | 如果 nonce 管理有缺陷，已执行的消息可能被重新执行 |
| 排序依赖 | 如果消息执行顺序错误，可能导致状态不一致 |
| Gas 不足 | 跨链调用的 gas 预估困难，可能导致目标链执行失败 |
