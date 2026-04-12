/**
 * DEX 聚合器：拆单路由演示
 * DEX Aggregator: Split Route Demo
 *
 * 展示如何通过 PTB 将一笔交易拆分到多个 DEX 池子执行。
 * Demonstrates how to split a single trade across multiple DEX pools using PTBs.
 */

import { Transaction } from '@mysten/sui/transactions';

// ============================================================
// 配置 — 替换为实际的 package/object ID
// Configuration — replace with actual package/object IDs
// ============================================================

const CONFIG = {
	CETUS_PACKAGE: '0xYOUR_CETUS_PACKAGE',
	DEEPBOOK_PACKAGE: '0xYOUR_DEEPBOOK_PACKAGE',
	USDC_TYPE: '0xYOUR_USDC_TYPE::USDC',
	SUI_TYPE: '0x2::sui::SUI',
};

// ============================================================
// 类型定义
// Type Definitions
// ============================================================

/** 拆单配置 / Split order configuration */
interface SplitOrder {
	poolId: string;         // DEX 池子对象 ID / DEX pool object ID
	dex: 'cetus' | 'deepbook';  // DEX 类型 / DEX type
	amount: number;         // 分配的输入金额 / Allocated input amount
}

// ============================================================
// 拆单路由 PTB 构建
// Split Route PTB Builder
// ============================================================

/**
 * 构建拆单路由 PTB
 * Build a PTB that splits a swap across multiple DEX pools.
 *
 * 核心流程 / Core flow:
 * 1. 从 gas coin 拆分出多个子金额 / Split gas coin into portions
 * 2. 每个 DEX 执行各自的 swap / Execute swap on each DEX
 * 3. 合并所有输出代币 / Merge all output coins
 * 4. 转账给发送者 / Transfer to sender
 */
function buildSplitRoutePTB(splits: SplitOrder[], totalAmountIn: number): Transaction {
	const tx = new Transaction();

	// Step 1: 拆分输入代币 / Split input coin into portions
	// tx.splitCoins 返回一个数组引用 / Returns an array of coin references
	const splitCoins = tx.splitCoins(
		tx.gas,
		splits.map((s) => tx.pure.u64(s.amount)),
	);

	// Step 2: 在每个 DEX 上执行 swap / Execute swap on each DEX
	const outputCoins = splits.map((split, i) => {
		// splitCoins 可能是数组或单个引用
		const coinIn = Array.isArray(splitCoins) ? splitCoins[i] : splitCoins;

		switch (split.dex) {
			case 'cetus':
				return tx.moveCall({
					target: `${CONFIG.CETUS_PACKAGE}::pool::swap_a_to_b`,
					arguments: [
						tx.object(split.poolId),
						coinIn,
						tx.pure.u64(0), // min_output = 0 (演示用 / for demo)
					],
					typeArguments: [CONFIG.SUI_TYPE, CONFIG.USDC_TYPE],
				});

			case 'deepbook':
				return tx.moveCall({
					target: `${CONFIG.DEEPBOOK_PACKAGE}::orderbook::market_order`,
					arguments: [
						tx.object(split.poolId),
						tx.pure.bool(true), // is_bid = true
						coinIn,
					],
					typeArguments: [CONFIG.SUI_TYPE, CONFIG.USDC_TYPE],
				});
		}
	});

	// Step 3: 合并所有输出 / Merge all output coins
	if (outputCoins.length > 1) {
		tx.mergeCoins(outputCoins[0], outputCoins.slice(1));
	}

	// Step 4: 转账给发送者 / Transfer to sender
	tx.transferObjects([outputCoins[0]], tx.gas);

	return tx;
}

// ============================================================
// 示例 / Example
// ============================================================

const demoSplits: SplitOrder[] = [
	{ poolId: '0xPOOL_A', dex: 'cetus', amount: 600_000_000_000 },     // 600 SUI
	{ poolId: '0xPOOL_B', dex: 'deepbook', amount: 400_000_000_000 },   // 400 SUI
];

console.log('=== DEX 聚合器：拆单路由演示 ===');
console.log('=== DEX Aggregator: Split Route Demo ===\n');
console.log('拆单配置 / Split config:', JSON.stringify(demoSplits, null, 2));

const tx = buildSplitRoutePTB(demoSplits, 1_000_000_000_000);
console.log('\nPTB 构建成功 / PTB built successfully');

console.log('\n执行步骤 / Execution steps:');
console.log('1. tx.splitCoins(gas, [600, 400]) → 拆分为两份');
console.log('2. 在 Cetus 上 swap 600 SUI → USDC');
console.log('3. 在 DeepBook 上 swap 400 SUI → USDC');
console.log('4. tx.mergeCoins() → 合并 USDC 输出');
console.log('5. tx.transferObjects() → 转账给用户');

console.log('\n要执行此 PTB / To execute:');
console.log('1. 替换 CONFIG 中的 package/object ID');
console.log('2. 提供一个有余额的 keypair');
console.log('3. 签名并执行交易 / Sign and execute the transaction');
