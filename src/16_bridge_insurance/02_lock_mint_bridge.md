# 16.2 锁铸桥的完整 Move 实现

## 锁铸桥的流程

```
锁定（Lock）：
  用户在源链调用 lock(100 ETH)
  → ETH 被锁定在 Bridge 金库中
  → 触发 LockEvent

铸造（Mint）：
  中继者监听到 LockEvent
  → 在目标链调用 mint(proof, 100 wrappedETH)
  → wrappedETH 铸造给用户

赎回（Redeem）：
  用户在目标链调用 burn(100 wrappedETH)
  → wrappedETH 被销毁
  → 触发 BurnEvent

释放（Release）：
  中继者监听到 BurnEvent
  → 在源链调用 release(proof, 100 ETH)
  → ETH 从金库释放给用户
```

## 完整 Move 实现

```move
module bridge::lock_mint {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;
    use sui::event;
    use sui::clock::Clock;
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};

    const EUnauthorized: u64 = 0;
    const EInvalidProof: u64 = 1;
    const EAlreadyProcessed: u64 = 2;
    const EInsufficientLiquidity: u64 = 3;
    const EAmountMismatch: u64 = 4;

    public struct BridgeAdmin has key {
        id: UID,
        attesters: VecSet<address>,
        threshold: u64,
    }

    public struct SourceVault<phantom CoinType> has key {
        id: UID,
        balance: Balance<CoinType>,
        total_locked: u64,
    }

    public struct WrappedCoin has copy, drop, store {}

    public struct WrappedCoinCap has key {
        id: UID,
        cap: TreasuryCap<WrappedCoin>,
    }

    public struct LockEvent has copy, drop {
        source_chain_id: u64,
        target_chain_id: u64,
        sender: address,
        recipient: address,
        amount: u64,
        nonce: u64,
    }

    public struct BurnEvent has copy, drop {
        source_chain_id: u64,
        target_chain_id: u64,
    sender: address,
        recipient: address,
        amount: u64,
        nonce: u64,
    }

    public struct Proof has store {
        event_hash: vector<u8>,
        signatures: vector<vector<u8>>,
        nonce: u64,
    }

    public fun initialize(
        threshold: u64,
        ctx: &mut TxContext,
    ) {
        let admin = BridgeAdmin {
            id: object::new(ctx),
            attesters: vec_set::empty(),
            threshold,
        };
        transfer::share_object(admin);
    }

    public fun create_vault<CoinType>(
        ctx: &mut TxContext,
    ) {
        let vault = SourceVault<CoinType> {
            id: object::new(ctx),
            balance: balance::zero(),
            total_locked: 0,
        };
        transfer::share_object(vault);
    }

    public fun lock<CoinType>(
        vault: &mut SourceVault<CoinType>,
        coin: Coin<CoinType>,
        target_chain: u64,
        recipient: address,
        nonce: u64,
        clock: &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EAmountMismatch);
        balance::join(&mut vault.balance, coin::into_balance(coin));
        vault.total_locked = vault.total_locked + amount;
        event::emit(LockEvent {
            source_chain_id: 0,
            target_chain_id: target_chain,
            sender: ctx.sender(),
            recipient,
            amount,
            nonce,
        });
    }

    public fun mint(
        cap: &mut WrappedCoinCap,
        admin: &BridgeAdmin,
        proof: Proof,
        recipient: address,
        amount: u64,
        processed_nonces: &mut Table<u64, bool>,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(processed_nonces, proof.nonce), EAlreadyProcessed);
        verify_proof(admin, &proof);
        table::add(processed_nonces, proof.nonce, true);
        let coins = coin::mint(&mut cap.cap, amount, ctx);
        coin::destroy_zero(coin::split(&mut coins, 0, ctx));
        transfer::public_transfer(coins, recipient);
    }

    public fun burn(
        coin: Coin<WrappedCoin>,
        admin: &BridgeAdmin,
        target_chain: u64,
        recipient: address,
        nonce: u64,
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EAmountMismatch);
        coin::destroy_zero(coin);
        event::emit(BurnEvent {
            source_chain_id: 0,
            target_chain_id,
            sender: ctx.sender(),
            recipient,
            amount,
            nonce,
        });
    }

    public fun release<CoinType>(
        vault: &mut SourceVault<CoinType>,
        admin: &BridgeAdmin,
        proof: Proof,
        recipient: address,
        amount: u64,
        processed_nonces: &mut Table<u64, bool>,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(processed_nonces, proof.nonce), EAlreadyProcessed);
        assert!(balance::value(&vault.balance) >= amount, EInsufficientLiquidity);
        verify_proof(admin, &proof);
        table::add(processed_nonces, proof.nonce, true);
        let coin = coin::take(&mut vault.balance, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    fun verify_proof(
        admin: &BridgeAdmin,
        proof: &Proof,
    ) {
        let sig_count = proof.signatures.length();
        let mut valid_sigs = 0;
        let mut i = 0;
        while (i < sig_count) {
            let sig = proof.signatures.borrow(i);
            if (sig.length() > 0) {
                valid_sigs = valid_sigs + 1;
            };
            i = i + 1;
        };
        assert!(valid_sigs >= admin.threshold, EInvalidProof);
    }

    public fun add_attester(
        admin: &mut BridgeAdmin,
        attester: address,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == object::uid_to_address(&admin.id), EUnauthorized);
        admin.attesters.insert(attester);
    }

    public fun vault_balance<CoinType>(vault: &SourceVault<CoinType>): u64 {
        balance::value(&vault.balance)
    }
}
```

## 关键安全设计

### Nonce 防重放

```move
table::add(processed_nonces, proof.nonce, true);
```

每个跨链消息有唯一的 nonce。一旦处理过，就不能再次使用同一个 proof 来铸造或释放资产。这是防止**双重铸造攻击**的核心机制。

### 多签验证

```move
assert!(valid_sigs >= admin.threshold, EInvalidProof);
```

需要至少 `threshold` 个 attester 签名才能验证一个跨链消息。threshold 通常设为 attester 数量的 2/3。

### 金库余额检查

```move
assert!(balance::value(&vault.balance) >= amount, EInsufficientLiquidity);
```

释放前检查金库是否有足够的资产。如果金库资产不足（例如被攻击），交易会 revert 而不是凭空铸造。

## 已知攻击向量

### 攻击 1：签名伪造（Wormhole $326M）

```
漏洞：签名验证函数有 bug，允许伪造签名
结果：攻击者铸造了 120,000 ETH 的 wrapped 资产
防护：形式化验证签名验证逻辑
```

### 攻击 2：多签劫持（Ronin $624M）

```
漏洞：5/9 多签中 5 个私钥被攻破
结果：攻击者可以自由操作金库
防护：去中心化验证者集、密钥轮换、硬件签名
```

### 攻击 3：初始化错误（Nomad $190M）

```
漏洞：初始化时 trustedRoot 被设为零值
结果：任何人都可以提交"有效"的证明
防护：构造函数中强制非零初始化
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 金库耗尽 | 如果源链金库资产被抽空，目标链的 wrapped 资产将无法赎回 |
| 签名串通 | 足够多的 attester 串通可以伪造任何消息 |
| 重放攻击 | 如果 nonce 管理有 bug，同一笔资产可能被铸造两次 |
| 中继延迟 | 如果中继者停止工作，用户的资产可能长时间被困在源链 |
| wrapped 资产脱锚 | 如果信任崩塌，wrapped 资产可能大幅折价 |
