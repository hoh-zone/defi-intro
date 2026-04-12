/**
 * 多跳交换演示 / Multi-Hop Swap Demo
 *
 * 展示如何在单个 PTB 中完成多跳路由（TokenA → TokenB → TokenC）。
 * Demonstrates multi-hop routing (TokenA → TokenB → TokenC) in a single PTB.
 *
 * 关键概念：PTB 命令结果链接
 * Key concept: PTB command result chaining
 * - Hop 1 的输出自动成为 Hop 2 的输入
 * - Output of Hop 1 automatically becomes input to Hop 2
 * - 原子性：任何一步失败，整个交易回滚
 * - Atomicity: if any hop fails, the entire transaction reverts
 */

import { Transaction } from '@mysten/sui/transactions';

const CONFIG = {
	DEX_PACKAGE: '0xYOUR_DEX_PACKAGE',
	TOKEN_A: '0x2::sui::SUI',           // SUI
	TOKEN_B: '0xYOUR_USDC_TYPE::USDC',   // USDC
	TOKEN_C: '0xYOUR_CETUS_TYPE::CETUS', // CETUS
};

/**
 * 构建多跳 swap PTB: TokenA → TokenB → TokenC
 * Build a multi-hop swap PTB: TokenA → TokenB → TokenC
 *
 * @param poolAB - A/B 交易对池子 ID / Pool ID for A/B pair
 * @param poolBC - B/C 交易对池子 ID / Pool ID for B/C pair
 * @param amountIn - 输入的 TokenA 数量 / Amount of TokenA to swap
 */
function buildMultiHopSwap(poolAB: string, poolBC: string, amountIn: number): Transaction {
	const tx = new Transaction();

	// Hop 1: Swap TokenA → TokenB
	// 使用命令结果链接 / Using command result chaining
	const [coinB] = tx.moveCall({
		target: `${CONFIG.DEX_PACKAGE}::pool::swap_exact_input`,
		arguments: [
			tx.object(poolAB),
			tx.splitCoins(tx.gas, [tx.pure.u64(amountIn)]),
			tx.pure.u64(0), // min_output (演示用 / for demo)
		],
		typeArguments: [CONFIG.TOKEN_A, CONFIG.TOKEN_B],
	});

	// Hop 2: Swap TokenB → TokenC
	// coinB 是 Hop 1 的输出，直接作为 Hop 2 的输入
	// coinB is the output of Hop 1, used directly as input to Hop 2
	const [coinC] = tx.moveCall({
		target: `${CONFIG.DEX_PACKAGE}::pool::swap_exact_input`,
		arguments: [
			tx.object(poolBC),
			coinB,              // ← 上一步的输出 / Output from previous step
			tx.pure.u64(0),     // min_output
		],
		typeArguments: [CONFIG.TOKEN_B, CONFIG.TOKEN_C],
	});

	// 转账最终输出给发送者 / Transfer final output to sender
	tx.transferObjects([coinC], tx.gas);

	return tx;
}

// ============================================================
// 路由比较 / Route Comparison
// ============================================================

/**
 * 对比：直接 swap vs 多跳 swap
 * Comparison: Direct swap vs Multi-hop swap
 *
 * 有时候 A→C 直接交易没有池子，但 A→B 和 B→C 都有。
 * Sometimes there's no direct A→C pool, but A→B and B→C exist.
 * 多跳让路由更灵活。
 * Multi-hop enables more flexible routing.
 */
function buildDirectSwap(poolAC: string, amountIn: number): Transaction {
	const tx = new Transaction();

	const [coinC] = tx.moveCall({
		target: `${CONFIG.DEX_PACKAGE}::pool::swap_exact_input`,
		arguments: [
			tx.object(poolAC),
			tx.splitCoins(tx.gas, [tx.pure.u64(amountIn)]),
			tx.pure.u64(0),
		],
		typeArguments: [CONFIG.TOKEN_A, CONFIG.TOKEN_C],
	});

	tx.transferObjects([coinC], tx.gas);
	return tx;
}

// ============================================================
// 示例输出 / Example Output
// ============================================================

console.log('=== 多跳交换演示 / Multi-Hop Swap Demo ===\n');

console.log('路由 / Route: SUI → USDC → CETUS');
console.log('');
console.log('关键概念 / Key concepts:');
console.log('- PTB 命令结果链接 / Command result chaining');
console.log('- Hop 1 输出 (coinB) 直接作为 Hop 2 输入 / Hop 1 output feeds into Hop 2');
console.log('- 原子执行：任一步失败全部回滚 / Atomic: any failure reverts everything');
console.log('');

const tx = buildMultiHopSwap('0xPOOL_AB', '0xPOOL_BC', 1_000_000_000_000);
console.log('多跳 PTB 构建成功 / Multi-hop PTB built successfully');

console.log('\n对比 / Comparison:');
console.log('- 直接 swap: 需要 A/C 池子存在 / Direct swap: requires A/C pool to exist');
console.log('- 多跳 swap: 通过中间代币路由 / Multi-hop: routes through intermediate token');
console.log('- Gas 成本: 多跳略高（多个 moveCall）/ Gas cost: multi-hop slightly higher');
