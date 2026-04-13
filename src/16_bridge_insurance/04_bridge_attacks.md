# 16.4 跨链桥攻击案例分析

## Ronin Bridge — $624M（2022 年 3 月）

### 桥的类型
锁铸桥，由 Sky Mavis（Axie Infinity 开发商）运营。

### 信任模型
```
验证者：9 个节点
阈值：5/9 多签

节点组成：
  - Sky Mavis：5 个节点
  - Axie DAO：2 个节点
  - 其他合作伙伴：2 个节点
```

### 攻击过程

```
1. 攻击者通过社会工程学获取了 Sky Mavis 4 个验证者的私钥
2. 攻击者通过 Axie DAO 的 gasless 交易功能获取了第 5 个签名
3. 5/9 阈值达成，攻击者可以：
   - 在以太坊金库中提取任意资产
   - 在 Ronin 链上伪造存款证明
4. 攻击者从以太坊金库提取：
   - 173,600 ETH
   - 25,500,000 USDC
   总价值约 $624M
```

### 根因分析

```
1. 中心化：9 个验证者中 5 个属于同一实体
2. 密钥管理：私钥存储在可被社会工程攻破的环境中
3. 无监控：大额提取没有延迟或告警机制
4. 无限额：没有单次提取上限
```

### Move 视角的防护

```move
module bridge::security_guard;
    use sui::clock::Clock;

    public struct WithdrawalLimit has store {
        daily_limit: u64,
        single_tx_limit: u64,
        delay_ms: u64,
    }

    public struct PendingWithdrawal has store {
        amount: u64,
        request_ms: u64,
        executed: bool,
    }

    public fun check_withdrawal(
        limit: &WithdrawalLimit,
        amount: u64,
        pending: &vector<PendingWithdrawal>,
        clock: &Clock,
    ): bool {
        if (amount > limit.single_tx_limit) { return false };
        let mut daily_total = 0u64;
        let now = clock.timestamp_ms();
        let mut i = 0;
        while (i < pending.length()) {
            let w = pending.borrow(i);
            if (!w.executed && now - w.request_ms < 86_400_000) {
                daily_total = daily_total + w.amount;
            };
            i = i + 1;
        };
        daily_total + amount <= limit.daily_limit
    }
```

## Wormhole — $326M（2022 年 2 月）

### 桥的类型
锁铸桥 + 消息传递，由 Certus One 运营 Guardian 网络。

### 攻击过程

```
1. Wormhole 在 Solana 上的核心合约有签名验证漏洞
2. 攻击者利用漏洞伪造了一个有效的 Guardian 签名
3. 使用伪造签名调用了 mint 函数
4. 铸造了 120,000 wrapped ETH
5. 将其中一部分换成其他资产
```

### 根因分析

```
漏洞位置：sysvar_account 验证逻辑

正确逻辑：
  验证签名来自 Guardian 网络

错误逻辑：
  跳过了签名验证（错误的 sysvar 检查）
  → 任何人都可以提交"有效"证明
```

### Move 视角的防护

Sui Move 的类型安全可以防止类似漏洞：

```move
module bridge::secure_verification;
    use sui::object::ID;

    public struct GuardianSignature has store {
        guardian_id: ID,
        signature: vector<u8>,
    }

    public struct VerifiedProof has store {
        hash: vector<u8>,
        guardian_count: u64,
    }

    public fun verify_quorum(
        signatures: &vector<GuardianSignature>,
        message_hash: &vector<u8>,
        threshold: u64,
    ): VerifiedProof {
        let mut valid = 0;
        let mut i = 0;
        while (i < signatures.length()) {
            let sig = signatures.borrow(i);
            if (verify_single_signature(sig, message_hash)) {
                valid = valid + 1;
            };
            i = i + 1;
        };
        assert!(valid >= threshold, 0);
        VerifiedProof {
            hash: *message_hash,
            guardian_count: valid,
        }
    }

    fun verify_single_signature(
        sig: &GuardianSignature,
        _hash: &vector<u8>,
    ): bool {
        sig.signature.length() >= 64
    }
```

Sui Move 的优势：`VerifiedProof` 是一个类型化的对象，只有通过 `verify_quorum` 函数才能创建。后续代码只需要检查 `VerifiedProof` 是否存在，不需要重新验证签名——**通过类型系统保证验证不被绕过**。

## Nomad — $190M（2022 年 8 月）

### 桥的类型
乐观桥。

### 攻击过程

```
1. 合约升级时，initialize 函数的 trustedRoot 被设为零值
2. 零值意味着：任何哈希都匹配"可信根"
3. 攻击者发现后，提交了任意消息
4. 消息被自动验证通过（因为 trustedRoot = 0）
5. 不仅攻击者可以利用，任何人都可以——变成了"抢劫"
6. 数百个地址参与了资金提取
```

### 根因分析

```
1. 初始化不完整：构造函数未强制设置 trustedRoot
2. 乐观验证的零值问题：0 == 0 始终为真
3. 升级流程缺陷：没有升级后的初始化验证
```

## 攻击模式总结

```
攻击类型        攻击面               防护
──────────────────────────────────────────────────────
私钥泄露        多签验证者           HSM、密钥轮换、多因素认证
签名验证漏洞    验证合约逻辑         形式化验证、审计
初始化错误      部署/升级流程        初始化检查、升级测试
权限滥用        管理员功能           时间锁、多签、限制
经济攻击        激励设计缺陷         经济模型审计
```

## 风险分析

| 教训 | 适用于 |
|---|---|
| 中心化 = 单点故障 | 所有桥——验证者越多越好 |
| 初始化是最容易被忽视的攻击面 | 所有合约 |
| 乐观验证的默认值必须安全 | 乐观桥 |
| 签名验证不能有 shortcut | 所有需要密码学验证的合约 |
| 大额操作需要延迟和限额 | 所有涉及资产的合约 |
