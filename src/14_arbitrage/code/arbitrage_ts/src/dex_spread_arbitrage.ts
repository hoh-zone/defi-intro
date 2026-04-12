/**
 * 闪电贷跨 DEX 套利演示 / Flash Loan Cross-DEX Arbitrage Demo
 *
 * 核心策略 / Core strategy:
 * 1. 闪电贷借入 SUI / Flash borrow SUI
 * 2. 在 DEX A 上将 SUI 换成 USDC（便宜的 USDC）/ Swap SUI → USDC on DEX A (cheaper USDC)
 * 3. 在 DEX B 上将 USDC 换回 SUI（贵的 USDC）/ Swap USDC → SUI on DEX B (dearer USDC)
 * 4. 偿还闪电贷 + 手续费 / Repay flash loan + fee
 * 5. 保留利润 / Keep profit
 *
 * 所有步骤在单个 PTB 中原子执行 / All steps execute atomically in a single PTB
 */

import { Transaction } from '@mysten/sui/transactions';

const CONFIG = {
	LENDING_PACKAGE: '0xYOUR_LENDING_PACKAGE',
	DEX_A_PACKAGE: '0xYOUR_DEX_A_PACKAGE',
	DEX_B_PACKAGE: '0xYOUR_DEX_B_PACKAGE',
	USDC_TYPE: '0xYOUR_USDC_TYPE::USDC',
	SUI_TYPE: '0x2::sui::SUI',
};

/**
 * 构建闪电贷套利 PTB
 * Build a flash loan arbitrage PTB
 *
 * 热土豆模式 / Hot potato pattern:
 * - borrow() 返回 (Coin, Receipt)
 * - Receipt 没有 drop ability → 必须在同一个交易中消费
 * - Receipt has no drop ability → MUST be consumed in the same transaction
 * - 唯一消费方式：repay() 函数
 * - Only way to consume: the repay() function
 */
function buildFlashLoanArbitrage(
	lendingPoolId: string,
	dexAPoolId: string,
	dexBPoolId: string,
	borrowAmount: number,
): Transaction {
	const tx = new Transaction();

	// Step 1: 闪电贷借入 SUI / Flash borrow SUI
	// 返回借款和热土豆收据 / Returns loan and hot-potato receipt
	const [loanCoin, receipt] = tx.moveCall({
		target: `${CONFIG.LENDING_PACKAGE}::flash_loan::borrow`,
		arguments: [
			tx.object(lendingPoolId),
			tx.pure.u64(borrowAmount),
		],
		typeArguments: [CONFIG.SUI_TYPE],
	});

	// Step 2: 在 DEX A 上 swap SUI → USDC / Swap SUI → USDC on DEX A
	const [usdcCoin] = tx.moveCall({
		target: `${CONFIG.DEX_A_PACKAGE}::pool::swap_a_to_b`,
		arguments: [
			tx.object(dexAPoolId),
			loanCoin,           // ← 使用借入的 SUI / Using borrowed SUI
			tx.pure.u64(0),     // min_output
		],
		typeArguments: [CONFIG.SUI_TYPE, CONFIG.USDC_TYPE],
	});

	// Step 3: 在 DEX B 上 swap USDC → SUI / Swap USDC → SUI on DEX B
	const [repayCoin] = tx.moveCall({
		target: `${CONFIG.DEX_B_PACKAGE}::pool::swap_b_to_a`,
		arguments: [
			tx.object(dexBPoolId),
			usdcCoin,           // ← 上一步的 USDC / USDC from previous step
			tx.pure.u64(0),     // min_output
		],
		typeArguments: [CONFIG.USDC_TYPE, CONFIG.SUI_TYPE],
	});

	// Step 4: 偿还闪电贷 / Repay flash loan
	// 消费热土豆收据 → 交易完成 / Consumes hot-potato receipt → transaction complete
	tx.moveCall({
		target: `${CONFIG.LENDING_PACKAGE}::flash_loan::repay`,
		arguments: [
			tx.object(lendingPoolId),
			receipt,            // ← 热土豆：必须消费 / Hot potato: must consume
			repayCoin,          // ← 还款金额必须 ≥ 借款 + 手续费 / Must be ≥ borrow + fee
		],
		typeArguments: [CONFIG.SUI_TYPE],
	});

	// 注意：如果 repayCoin 不足以支付借款 + 手续费，repay() 会 abort
	// 整个交易回滚，就像什么都没发生过
	// Note: if repayCoin < borrow + fee, repay() aborts
	// Entire transaction reverts as if nothing happened

	return tx;
}

// ============================================================
// 示例输出 / Example Output
// ============================================================

console.log('=== 闪电贷跨 DEX 套利演示 ===');
console.log('=== Flash Loan Cross-DEX Arbitrage Demo ===\n');

console.log('策略 / Strategy:');
console.log('  借入 SUI → 在 DEX A 买便宜 USDC → 在 DEX B 卖贵 USDC → 还款 + 利润');
console.log('  Borrow SUI → Buy cheap USDC on DEX A → Sell dear USDC on DEX B → Repay + profit\n');

console.log('关键概念 / Key concepts:');
console.log('  1. 闪电贷提供零资本交易 / Flash loan enables zero-capital trading');
console.log('  2. PTB 原子性：还款失败则全部回滚 / PTB atomicity: revert on repayment failure');
console.log('  3. 热土豆模式强制同笔交易还款 / Hot potato enforces same-tx repayment');

const tx = buildFlashLoanArbitrage(
	'0xLENDING_POOL',
	'0xDEX_A_POOL',
	'0xDEX_B_POOL',
	10_000_000_000_000, // 10,000 SUI
);

console.log('\nPTB 构建成功 / PTB built successfully');
