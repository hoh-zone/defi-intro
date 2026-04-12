/**
 * 清算套利演示 / Liquidation Arbitrage Demo
 *
 * 清算是 DeFi 中的一种套利形式 / Liquidation is a form of DeFi arbitrage:
 * - 清算者以折扣价偿还债务 < 抵押品价值 / Liquidator repays debt at discount < collateral value
 * - 清算奖金（通常 5-10%）是利润来源 / Liquidation bonus (typically 5-10%) is the profit
 * - 速度很重要：第一个清算者赢得机会 / Speed matters: first liquidator wins
 *
 * 风险 / Risks:
 * - 抢跑失败浪费 Gas / Failed liquidation wastes gas (someone was faster)
 * - 抵押品价格可能在清算和出售之间下跌 / Collateral may drop between liquidation and sale
 */

import { Transaction } from '@mysten/sui/transactions';

const CONFIG = {
	LENDING_PACKAGE: '0xYOUR_LENDING_PACKAGE',
	USDC_TYPE: '0xYOUR_USDC_TYPE::USDC',
	SUI_TYPE: '0x2::sui::SUI',
};

/**
 * 构建清算套利 PTB
 * Build a liquidation arbitrage PTB
 *
 * 流程 / Flow:
 * 1. 闪电贷借入债务代币 (USDC) / Flash borrow debt token (USDC)
 * 2. 清算不健康的仓位（偿还债务，没收抵押品折扣）/ Liquidate unhealthy position
 * 3. 出售没收的抵押品获利 / Sell seized collateral for profit
 * 4. 偿还闪电贷 / Repay flash loan
 */
function buildLiquidationArbitrage(
	lendingPoolId: string,
	flashPoolId: string,
	positionId: string,
	repayAmount: number,
): Transaction {
	const tx = new Transaction();

	// Step 1: 闪电贷借入 USDC 用于偿还债务 / Flash borrow USDC to repay debt
	const [loanCoin, receipt] = tx.moveCall({
		target: `${CONFIG.LENDING_PACKAGE}::flash_loan::borrow`,
		arguments: [
			tx.object(flashPoolId),
			tx.pure.u64(repayAmount),
		],
		typeArguments: [CONFIG.USDC_TYPE],
	});

	// Step 2: 清算仓位 / Liquidate the position
	// 偿还债务 → 没收抵押品 + 清算奖金 / Repay debt → seize collateral + bonus
	const [seizedCollateral] = tx.moveCall({
		target: `${CONFIG.LENDING_PACKAGE}::market::liquidate`,
		arguments: [
			tx.object(lendingPoolId),
			tx.object(positionId),  // 不健康的仓位 / Underwater position
			loanCoin,               // 借入的 USDC / Borrowed USDC
		],
		typeArguments: [CONFIG.SUI_TYPE, CONFIG.USDC_TYPE],
	});

	// Step 3: 偿还闪电贷（用没收的 SUI 抵押品）/ Repay flash loan with seized SUI
	// 注意：实际中可能需要先 swap SUI → USDC 来还款
	// Note: in practice may need to swap SUI → USDC first to repay
	tx.moveCall({
		target: `${CONFIG.LENDING_PACKAGE}::flash_loan::repay`,
		arguments: [
			tx.object(flashPoolId),
			receipt,                // 热土豆收据 / Hot potato receipt
			seizedCollateral,       // 没收的抵押品 / Seized collateral
		],
		typeArguments: [CONFIG.USDC_TYPE],
	});

	return tx;
}

// ============================================================
// 清算监控逻辑 (伪代码) / Liquidation Monitoring Logic (pseudocode)
// ============================================================

interface Position {
	id: string;
	owner: string;
	collateralAmount: number;
	debtAmount: number;
	healthFactor: number; // < 1.0 = 可清算 / liquidatable
}

/**
 * 清算机器人核心循环 (伪代码)
 * Liquidation bot main loop (pseudocode)
 *
 * 实际实现需要使用 SuiGrpcClient 订阅链上事件
 * Actual implementation needs SuiGrpcClient to subscribe to on-chain events
 */
function monitorAndLiquidate(positions: Position[]): void {
	for (const pos of positions) {
		if (pos.healthFactor < 1.0) {
			console.log(`发现可清算仓位 / Found liquidatable position: ${pos.id}`);
			console.log(`  健康因子 / Health factor: ${pos.healthFactor}`);
			console.log(`  债务 / Debt: ${pos.debtAmount} USDC`);
			console.log(`  抵押品 / Collateral: ${pos.collateralAmount} SUI`);

			// 在实际中，这里构建并执行清算 PTB
			// In practice, build and execute the liquidation PTB here
			const profit = pos.collateralAmount * 0.05 - pos.debtAmount * 0.001; // 粗略估算
			console.log(`  预计利润 / Estimated profit: ${profit.toFixed(2)} SUI`);
		}
	}
}

// ============================================================
// 示例输出 / Example Output
// ============================================================

console.log('=== 清算套利演示 ===');
console.log('=== Liquidation Arbitrage Demo ===\n');

console.log('清算是 DeFi 套利的一种形式 / Liquidation is a form of DeFi arbitrage:');
console.log('  - 以折扣价偿还债务 / Repay debt at discount');
console.log('  - 清算奖金（通常 5-10%）是利润来源 / Liquidation bonus (5-10%) is profit');
console.log('  - 速度很关键：第一个清算者赢得机会 / Speed is key: first liquidator wins\n');

const tx = buildLiquidationArbitrage(
	'0xLENDING_POOL',
	'0xFLASH_POOL',
	'0xPOSITION',
	5_000_000_000_000, // 5,000 USDC
);
console.log('清算 PTB 构建成功 / Liquidation PTB built successfully\n');

// 模拟清算监控
const mockPositions: Position[] = [
	{ id: '0xPOS_1', owner: '0xA', collateralAmount: 1000, debtAmount: 800, healthFactor: 0.85 },
	{ id: '0xPOS_2', owner: '0xB', collateralAmount: 5000, debtAmount: 3000, healthFactor: 1.2 },
	{ id: '0xPOS_3', owner: '0xC', collateralAmount: 2000, debtAmount: 1500, healthFactor: 0.95 },
];

console.log('模拟清算监控 / Simulated liquidation monitoring:');
monitorAndLiquidate(mockPositions);
