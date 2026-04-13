# 21.5 多签钱包与密钥管理

## 为什么 DeFi 协议需要多签

单密钥管理的风险：
- 私钥泄露 → 所有权限被接管
- 密钥持有者失联 → 协议无法治理
- 内部作恶 → 无制衡机制

多签（Multisig）要求 N 个参与方中至少 M 个同意才能执行交易。Sui 原生支持多签。

## Sui 多签原理

Sui 的多签基于 K-of-N 门限签名：

1. 生成 N 个公钥-私钥对
2. 组合公钥创建多签地址
3. 发起交易时，收集至少 K 个签名
4. Sui 验证器验证签名数量和权重

```bash
# 创建多签地址（3-of-5）
sui keytool multiaddr \
  $(sui keytool list --json | jq -r '.[0].suiAddress') \
  $(sui keytool list --json | jq -r '.[1].suiAddress') \
  $(sui keytool list --json | jq -r '.[2].suiAddress') \
  $(sui keytool list --json | jq -r '.[3].suiAddress') \
  $(sui keytool list --json | jq -r '.[4].suiAddress') \
  --threshold 3
```

## 密钥角色分离方案

生产级 DeFi 协议建议使用以下角色分离：

| 角色 | 多签配置 | 持有的 Capability | 用途 |
|------|----------|-------------------|------|
| 暂停委员会 | 2-of-3 | PauseCap | 紧急暂停 |
| 参数委员会 | 3-of-5 | ParamsCap | 利率、费用等参数调整 |
| 升级委员会 | 4-of-7 | UpgradeCap | 合约升级 |
| 国库管理 | 3-of-5 | TreasuryCap | 资金提取 |
| 紧急响应 | 2-of-3 | EmergencyCap | 紧急关停 |

```move
module defi::governance_setup {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;

    public struct PauseCap has key, store { id: UID }
    public struct ParamsCap has key, store { id: UID }
    public struct UpgradeCapHolder has key, store { id: UID }
    public struct EmergencyCap has key, store { id: UID }

    public fun init(
        pause_multisig: address,
        params_multisig: address,
        emergency_multisig: address,
        ctx: &mut TxContext,
    ) {
        transfer::public_transfer(
            PauseCap { id: object::new(ctx) },
            pause_multisig,
        );
        transfer::public_transfer(
            ParamsCap { id: object::new(ctx) },
            params_multisig,
        );
        transfer::public_transfer(
            EmergencyCap { id: object::new(ctx) },
            emergency_multisig,
        );
    }
}
```

`init` 函数接收多个多签地址，将 Capability 分配到对应的多签钱包。部署时通过 PTB 传入参数。

## 时间锁（Timelock）

关键治理操作应该加入延迟执行期，给社区留出审查时间：

```move
module defi::timelock {
    use sui::object::{Self, ID, UID};
    use sui::event;
    use sui::clock::Clock;

    public struct Timelock has key {
        id: UID,
        min_delay: u64,
        max_delay: u64,
    }

    public struct ScheduledOp has key, store {
        id: UID,
        target_function: String,
        parameters: vector<u8>,
        execute_after: u64,
        executed: bool,
        cancelled: bool,
    }

    public struct OperationScheduled has copy, drop {
        op_id: ID,
        execute_after: u64,
    }

    public struct OperationExecuted has copy, drop {
        op_id: ID,
    }

    public struct OperationCancelled has copy, drop {
        op_id: ID,
    }

    public fun schedule(
        _: &Timelock,
        target_function: String,
        parameters: vector<u8>,
        delay_ms: u64,
        ctx: &mut TxContext,
    ) {
        let timelock = &Timelock { id: object::new(ctx), min_delay: 0, max_delay: 0 };
        assert!(delay_ms >= timelock.min_delay, EDelayTooShort);
        assert!(delay_ms <= timelock.max_delay, EDelayTooLong);

        let now = sui::clock::timestamp_ms(clock);
        let execute_after = now + delay_ms;

        let op = ScheduledOp {
            id: object::new(ctx),
            target_function,
            parameters,
            execute_after,
            executed: false,
            cancelled: false,
        };

        event::emit(OperationScheduled {
            op_id: object::id(&op),
            execute_after,
        });

        transfer::public_share_object(op);
    }

    public fun execute(op: &mut ScheduledOp, clock: &Clock) {
        assert!(!op.executed, EAlreadyExecuted);
        assert!(!op.cancelled, ECancelled);
        assert!(
            sui::clock::timestamp_ms(clock) >= op.execute_after,
            ETooEarly
        );

        op.executed = true;
        event::emit(OperationExecuted { op_id: object::id(op) });
    }

    public fun cancel(op: &mut ScheduledOp) {
        assert!(!op.executed, EAlreadyExecuted);
        op.cancelled = true;
        event::emit(OperationCancelled { op_id: object::id(op) });
    }

    const EDelayTooShort: u64 = 0;
    const EDelayTooLong: u64 = 1;
    const EAlreadyExecuted: u64 = 2;
    const ECancelled: u64 = 3;
    const ETooEarly: u64 = 4;
}
```

### 带时间锁的参数更新

```move
module defi::timelocked_params {
    use defi::timelock::{Self, Timelock};
    use sui::object::{Self, UID};

    public struct ParamsCap has key, store { id: UID }

    public struct ProtocolParams has key {
        id: UID,
        fee_rate: u64,
        liquidation_threshold: u64,
    }

    public fun propose_fee_change(
        _: &ParamsCap,
        timelock: &Timelock,
        new_fee: vector<u8>,
        ctx: &mut TxContext,
    ) {
        timelock::schedule(
            timelock,
            string(b"set_fee_rate"),
            new_fee,
            86400000,
            ctx,
        );
    }
}
```

关键治理操作（费率调整、清算阈值修改）必须经过 24 小时的时间锁。社区可以在延迟期内审查并取消恶意提案。

## 密钥轮换

多签参与者的密钥应该定期轮换：

```move
module defi::key_rotation {
    use sui::object::{Self, UID};
    use sui::event;

    public struct CommitteeCap has key, store { id: UID }

    public struct Committee has key {
        id: UID,
        members: vector<address>,
        threshold: u64,
        version: u64,
    }

    public struct MemberRotated has copy, drop {
        old_member: address,
        new_member: address,
        version: u64,
    }

    public fun rotate_member(
        _: &CommitteeCap,
        committee: &mut Committee,
        old_member: address,
        new_member: address,
    ) {
        let found = false;
        let len = vector::length(&committee.members);
        let mut i = 0;
        while (i < len) {
            if (*vector::borrow(&committee.members, i) == old_member) {
                *vector::borrow_mut(&mut committee.members, i) = new_member;
                found = true;
            };
            i = i + 1;
        };
        assert!(found, EMemberNotFound);

        committee.version = committee.version + 1;

        event::emit(MemberRotated {
            old_member,
            new_member,
            version: committee.version,
        });
    }

    const EMemberNotFound: u64 = 0;
}
```

## 多签 + 时间锁的治理架构

```
┌─────────────────────────────────────────┐
│              治理提案                     │
│  1. 参数委员会发起 (3-of-5 多签)          │
│  2. 时间锁延迟 24-72 小时                 │
│  3. 社区审查期（可取消）                   │
│  4. 自动执行                              │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│              紧急暂停                     │
│  1. 暂停委员会发起 (2-of-3 多签)          │
│  2. 无时间锁（紧急情况不能等）             │
│  3. 恢复需要更高门槛 (3-of-5)             │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│              合约升级                     │
│  1. 升级委员会发起 (4-of-7 多签)          │
│  2. 时间锁延迟 7 天                       │
│  3. 代码审计报告公开                       │
│  4. 社区投票（可选）                       │
│  5. 执行升级                              │
└─────────────────────────────────────────┘
```

## 小结

多签和时间锁是 DeFi 治理安全的两大支柱。角色分离确保单一权限泄漏不会威胁整个协议。时间锁给社区留出反应窗口。密钥轮换减少长期暴露风险。每一层都是"信任但不盲目信任"的体现。
