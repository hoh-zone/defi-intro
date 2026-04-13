## 2.3 交易生命周期与 PTB

### Programmable Transaction Blocks

Sui 引入了 **PTB（Programmable Transaction Blocks）**——在一个交易块中组合多个操作，原子执行。如果其中任何一个操作失败，整个交易回滚。

这对 DeFi 有直接影响：原本需要多笔交易才能完成的策略，现在可以在一个 PTB 中原子完成。

```typescript
// TypeScript SDK 示例：在一个 PTB 中完成闪电贷 + 套利 + 还款
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";

async function flashLoanArbitrage(
  keypair: Ed25519Keypair,
  lendingPoolId: string,
  dexPoolAId: string,
  dexPoolBId: string,
  amount: number,
) {
  const client = new SuiGrpcClient({ network: 'mainnet' });
  const tx = new Transaction();

  // 步骤1：从借贷池闪电贷借出 SUI
  const loanCoin = tx.moveCall({
    target: "0xLENDING::lending::flash_borrow",
    arguments: [tx.object(lendingPoolId), tx.pure.u64(amount)],
  });

  // 步骤2：在 DEX A 上将 SUI 换成 USDC
  const usdcCoin = tx.moveCall({
    target: "0xDEX_A::pool::swap_sui_to_usdc",
    arguments: [tx.object(dexPoolAId), loanCoin],
  });

  // 步骤3：在 DEX B 上将 USDC 换回 SUI（利用价差）
  const repaidCoin = tx.moveCall({
    target: "0xDEX_B::pool::swap_usdc_to_sui",
    arguments: [tx.object(dexPoolBId), usdcCoin],
  });

  // 步骤4：还款
  tx.moveCall({
    target: "0xLENDING::lending::flash_repay",
    arguments: [tx.object(lendingPoolId), repaidCoin],
  });

  // 所有步骤要么全部成功，要么全部回滚
  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction: tx,
  });

  if (result.$kind === 'FailedTransaction') {
    throw new Error(`Transaction failed: ${result.FailedTransaction.status.error?.message}`);
  }

  return result;
}
```

PTB 的原子性保证：如果步骤4中还款金额不足（套利价差不够覆盖手续费），整个交易回滚——步骤2和3的 swap 也不会执行。

### Gas 预算与交易失败模式

每笔交易都有 Gas 预算。Gas 消耗由计算、存储和共识三部分组成。交易失败有两种模式：

**执行失败（Abort）**：代码中 `assert!` 条件不满足或 `abort` 被调用。状态完全回滚，已消耗的 Gas 不退还。

```move
public entry fun swap_with_checks(
    pool: &mut Pool,
    coin_in: Coin<SUI>,
    min_out: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(!pool.paused, EPaused);
    let amount_out = calculate_out(pool, coin_in.value(&coin_in));
    assert!(amount_out >= min_out, ESlippageExceeded);
    execute_swap(pool, coin_in, ctx)
}

#[error]
const EPaused: vector<u8> = b"Paused";
#[error]
const ESlippageExceeded: vector<u8> = b"Slippage Exceeded";
```

`min_out` 参数是用户的滑点保护。如果实际输出低于 `min_out`，交易 abort，状态回滚。Gas 已经消耗，但至少防止了不利的交易执行。

**Gas 耗尽（Out of Gas）**：交易执行到一半 Gas 用完。状态回滚，但 Gas 费用已经被验证者收取。

> 风险提示：PTB 的原子性是双刃剑。它保证了操作的原子性，但也意味着一个复杂的 PTB 如果在最后一步失败，之前所有步骤的计算 Gas 都被浪费。在编写复杂的 DeFi 操作（如多跳套利）时，应该仔细估算 Gas 预算，并考虑在最外层设置合理的 Gas limit。
