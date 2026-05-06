/// 教学级 Yield Vault 实现
/// 展示 Yearn 风格收益金库的核心机制：
/// - 份额代币模型（price_per_share 单调递增）
/// - 自动复投逻辑（harvest）
/// - 管理费与绩效费
#[allow(duplicate_alias, unused_const)]
module yield_vault::yield_vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

// ============ Errors ============

const ENotOwner: u64 = 0;
const EZeroDeposit: u64 = 1;
const EZeroWithdraw: u64 = 2;
const EInsufficientShares: u64 = 3;
const EZeroProfit: u64 = 4;

const PRECISION: u64 = 1_000_000_000; // 9 位精度

// ============ Structs ============

/// Yield Vault：存入 Asset 类型的代币，赚取收益
/// 份额价值 = total_balance / total_shares，随收益累积单调递增
public struct Vault<phantom Asset> has key {
    id: UID,
    /// Vault 持有的底层资产
    balance: Balance<Asset>,
    /// 总份额数
    total_shares: u64,
    /// 策略配置（教学用简化）
    strategy: Strategy,
    /// 提款手续费（基点）
    withdrawal_fee_bps: u64,
    /// 绩效费（基点）
    performance_fee_bps: u64,
    /// 累积的管理费
    fees_collected: Balance<Asset>,
    /// Vault 管理员
    owner: address,
}

/// 策略配置（教学用占位）
public struct Strategy has store {
    /// 策略名称
    name: vector<u8>,
    /// 上次复投时间（毫秒时间戳）
    last_harvest_ms: u64,
    /// 复投间隔（毫秒）
    harvest_interval_ms: u64,
    /// 累计收益
    total_earned: u64,
}

/// 用户持有的 Vault 份额凭证
public struct VaultReceipt has key, store {
    id: UID,
    vault_id: ID,
    shares: u64,
}

/// 管理员能力对象
public struct VaultAdminCap has key, store {
    id: UID,
    vault_id: ID,
}

// ============ Events ============

public struct VaultCreated has copy, drop {
    vault_id: ID,
}

public struct Deposited has copy, drop {
    user: address,
    amount: u64,
    shares_minted: u64,
    price_per_share: u64,
}

public struct Withdrawn has copy, drop {
    user: address,
    shares_burned: u64,
    amount: u64,
    fee: u64,
}

public struct Harvested has copy, drop {
    profit: u64,
    performance_fee: u64,
    new_price_per_share: u64,
}

public struct FeesCollected has copy, drop {
    amount: u64,
}

// ============ Create ============

/// 创建新的 Yield Vault
/// 初始存入一笔资产以设定 price_per_share = PRECISION
public fun create<Asset>(
    initial: Coin<Asset>,
    withdrawal_fee_bps: u64,
    performance_fee_bps: u64,
    ctx: &mut TxContext,
): VaultAdminCap {
    let amount = coin::value(&initial);
    assert!(amount > 0, EZeroDeposit);

    let vault_id = object::new(ctx);
    let vault_id_copy = object::uid_to_inner(&vault_id);

    let vault = Vault<Asset> {
        id: vault_id,
        balance: coin::into_balance(initial),
        total_shares: amount,
        strategy: Strategy {
            name: b"auto_compound",
            last_harvest_ms: 0,
            harvest_interval_ms: 86_400_000, // 24 小时
            total_earned: 0,
        },
        withdrawal_fee_bps,
        performance_fee_bps,
        fees_collected: balance::zero(),
        owner: ctx.sender(),
    };

    let admin_cap = VaultAdminCap {
        id: object::new(ctx),
        vault_id: vault_id_copy,
    };

    transfer::share_object(vault);
    event::emit(VaultCreated { vault_id: vault_id_copy });
    admin_cap
}

// ============ View Functions ============

/// 每份额净值（以 Asset 的最小单位计）
public fun price_per_share<Asset>(vault: &Vault<Asset>): u64 {
    if (vault.total_shares == 0) { return PRECISION };
    (((balance::value(&vault.balance) as u128) * (PRECISION as u128) /
        (vault.total_shares as u128)) as u64)
}

/// Vault 管理的总资产
public fun total_assets<Asset>(vault: &Vault<Asset>): u64 {
    balance::value(&vault.balance)
}

/// 总份额数
public fun total_shares<Asset>(vault: &Vault<Asset>): u64 {
    vault.total_shares
}

// ============ Deposit ============

/// 存入资产，获得份额凭证
public fun deposit<Asset>(
    vault: &mut Vault<Asset>,
    coin: Coin<Asset>,
    ctx: &mut TxContext,
): VaultReceipt {
    let amount = coin::value(&coin);
    assert!(amount > 0, EZeroDeposit);

    // 按当前净值计算份额
    let shares = if (vault.total_shares == 0) {
        amount
    } else {
        (((amount as u128) * (vault.total_shares as u128) /
            (balance::value(&vault.balance) as u128)) as u64)
    };
    assert!(shares > 0, EZeroDeposit);

    let pps = price_per_share(vault);

    balance::join(&mut vault.balance, coin::into_balance(coin));
    vault.total_shares = vault.total_shares + shares;

    let receipt = VaultReceipt {
        id: object::new(ctx),
        vault_id: object::id(vault),
        shares,
    };

    event::emit(Deposited {
        user: ctx.sender(),
        amount,
        shares_minted: shares,
        price_per_share: pps,
    });

    receipt
}

// ============ Withdraw ============

/// 凭份额凭证赎回资产
public fun withdraw<Asset>(
    vault: &mut Vault<Asset>,
    receipt: VaultReceipt,
    ctx: &mut TxContext,
): Coin<Asset> {
    let VaultReceipt { id, shares, vault_id: _ } = receipt;
    assert!(shares > 0, EZeroWithdraw);
    assert!(shares <= vault.total_shares, EInsufficientShares);

    // 计算赎回金额
    let gross_amount = (((shares as u128) * (balance::value(&vault.balance) as u128) /
        (vault.total_shares as u128)) as u64);

    // 扣除提款手续费
    let fee = gross_amount * vault.withdrawal_fee_bps / 10000;
    let net_amount = gross_amount - fee;

    // 先从余额中取出总额
    let mut withdrawn = balance::split(&mut vault.balance, gross_amount);

    // 将手续费部分转入 fees_collected
    if (fee > 0) {
        balance::join(&mut vault.fees_collected, balance::split(&mut withdrawn, fee));
    };

    vault.total_shares = vault.total_shares - shares;
    object::delete(id);

    event::emit(Withdrawn {
        user: ctx.sender(),
        shares_burned: shares,
        amount: net_amount,
        fee,
    });

    coin::from_balance(withdrawn, ctx)
}

// ============ Harvest (复投) ============

/// 将策略收益注入 Vault（由管理员/keeper 调用）
/// 关键不变量：只能增加 price_per_share
public fun harvest<Asset>(
    _: &VaultAdminCap,
    vault: &mut Vault<Asset>,
    profit: Coin<Asset>,
    clock_ms: u64,
    _ctx: &mut TxContext,
) {
    let profit_amount = coin::value(&profit);
    assert!(profit_amount > 0, EZeroProfit);

    // 扣除绩效费
    let perf_fee = profit_amount * vault.performance_fee_bps / 10000;
    let net_profit = profit_amount - perf_fee;

    let mut profit_balance = coin::into_balance(profit);
    if (perf_fee > 0) {
        balance::join(&mut vault.fees_collected, balance::split(&mut profit_balance, perf_fee));
    };
    balance::join(&mut vault.balance, profit_balance);

    // 更新策略统计
    vault.strategy.total_earned = vault.strategy.total_earned + net_profit;
    vault.strategy.last_harvest_ms = clock_ms;

    let new_pps = price_per_share(vault);

    event::emit(Harvested {
        profit: net_profit,
        performance_fee: perf_fee,
        new_price_per_share: new_pps,
    });
}

// ============ Admin ============

/// 管理员提取累积的费用
public fun collect_fees<Asset>(
    _: &VaultAdminCap,
    vault: &mut Vault<Asset>,
    ctx: &mut TxContext,
): Coin<Asset> {
    let amount = balance::value(&vault.fees_collected);
    let coins = coin::take(&mut vault.fees_collected, amount, ctx);
    event::emit(FeesCollected { amount });
    coins
}

// ============ Tests ============

#[test_only]
fun create_for_testing<Asset>(
    initial: Coin<Asset>,
    withdrawal_fee_bps: u64,
    performance_fee_bps: u64,
    ctx: &mut TxContext,
): (Vault<Asset>, VaultAdminCap) {
    let amount = coin::value(&initial);
    assert!(amount > 0, EZeroDeposit);

    let vault_id = object::new(ctx);
    let vault_id_copy = object::uid_to_inner(&vault_id);

    let vault = Vault<Asset> {
        id: vault_id,
        balance: coin::into_balance(initial),
        total_shares: amount,
        strategy: Strategy {
            name: b"auto_compound",
            last_harvest_ms: 0,
            harvest_interval_ms: 86_400_000,
            total_earned: 0,
        },
        withdrawal_fee_bps,
        performance_fee_bps,
        fees_collected: balance::zero(),
        owner: ctx.sender(),
    };

    let admin_cap = VaultAdminCap {
        id: object::new(ctx),
        vault_id: vault_id_copy,
    };

    (vault, admin_cap)
}

#[test]
fun create_vault() {
    use std::unit_test::destroy;
    use sui::sui::SUI;
    use sui::tx_context;

    let mut ctx = tx_context::dummy();
    let initial = coin::mint_for_testing<SUI>(1000_000_000_000, &mut ctx);
    let (vault, admin_cap) = create_for_testing<SUI>(initial, 10, 1000, &mut ctx);

    assert!(total_shares(&vault) == 1000_000_000_000);
    assert!(total_assets(&vault) == 1000_000_000_000);
    assert!(price_per_share(&vault) == PRECISION);
    destroy(vault);
    destroy(admin_cap);
}

#[test]
fun deposit_and_withdraw() {
    use std::unit_test::destroy;
    use sui::sui::SUI;
    use sui::tx_context;

    let mut ctx = tx_context::dummy();
    let initial = coin::mint_for_testing<SUI>(1000_000_000_000, &mut ctx);
    let (mut vault, admin_cap) = create_for_testing<SUI>(initial, 10, 1000, &mut ctx);

    let deposit_coin = coin::mint_for_testing<SUI>(500_000_000_000, &mut ctx);
    let receipt = deposit(&mut vault, deposit_coin, &mut ctx);

    assert!(receipt.shares == 500_000_000_000);
    assert!(total_shares(&vault) == 1500_000_000_000);

    let withdrawn = withdraw(&mut vault, receipt, &mut ctx);
    let withdrawn_amount = coin::value(&withdrawn);

    assert!(withdrawn_amount == 499_500_000_000);
    destroy(withdrawn);
    destroy(vault);
    destroy(admin_cap);
}
