# 14.6 跨协议组合套利

## 为什么需要跨协议

单一协议的套利空间有限（价差通常很快被消除）。真正的利润来自**跨协议组合**——利用不同协议之间的定价偏差。

## 四种跨协议套利模式

### 1. DEX + 借贷组合

利用借贷利率和 DEX 收益率的差异：

```
DEX LP 收益: 15% APY
借贷借款利率: 8% APY

操作:
  1. 在借贷协议借出 USDC（付 8%）
  2. 在 DEX 提供 USDC/SUI 流动性（赚 15%）
  3. 净收益: 15% - 8% = 7%

风险: 无常损失 + 利率变化
```

### 2. CDP + DEX 锚定套利

当 CDP 稳定币脱锚时：

```
稳定币 sUSD 交易价 $0.95（脱锚 5%）

操作:
  1. 在 DEX 用 $0.95 买入 sUSD
  2. 在 CDP 用 sUSD 赎回 $1.00 的抵押品
  3. 利润: $0.05/sUSD

自我修正: 买入推高 sUSD 价格，赎回减少供给，价格回到 $1
```

### 3. LSD + 借贷循环

```
操作:
  1. 质押 SUI 获得 afSUI
  2. 在借贷协议用 afSUI 作抵押借出 SUI
  3. 再次质押借出的 SUI
  4. 重复 → 放大质押收益

风险: 利率上升、LST 折价、清算
```

### 4. 衍生品基差套利

```
永续合约价格: $2.10/SUI
现货价格: $2.00/SUI
基差: $0.10 (5%)

操作:
  1. 买入现货 SUI
  2. 做空永续合约
  3. 赚取基差（随时间收敛到 0）

风险: 资金费率变化、持仓成本
```

## Move 实现：跨协议套利框架

```move
module cross_protocol_arbitrage {
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};

    public struct ArbitragePath has store {
        steps: vector<Step>,
        expected_output: u64,
        max_slippage_bps: u64,
    }

    public struct Step has store {
        protocol: u8,
        action: u8,
        input_token: u8,
        output_token: u8,
        pool_id: ID,
    }

    const PROTOCOL_DEX: u8 = 0;
    const PROTOCOL_LENDING: u8 = 1;
    const PROTOCOL_CDP: u8 = 2;
    const PROTOCOL_PERP: u8 = 3;

    const ACTION_SWAP: u8 = 0;
    const ACTION_BORROW: u8 = 1;
    const ACTION_REPAY: u8 = 2;
    const ACTION_MINT: u8 = 3;
    const ACTION_REDEEM: u8 = 4;
    const ACTION_OPEN_SHORT: u8 = 5;
    const ACTION_CLOSE_SHORT: u8 = 6;

    public fun execute_path<Start, End>(
        path: &ArbitragePath,
        start_coin: Coin<Start>,
        ctx: &mut TxContext,
    ): Coin<End> {
        let mut current_coin: Coin<Any> = start_coin;
        let mut i = 0;
        while (i < vector::length(&path.steps)) {
            let step = vector::borrow(&path.steps, i);
            current_coin = execute_step(step, current_coin, ctx);
            i = i + 1;
        };
        current_coin
    }

    fun execute_step(
        step: &Step,
        input: Coin<Any>,
        ctx: &mut TxContext,
    ): Coin<Any> {
        match (step.protocol) {
            PROTOCOL_DEX => execute_dex_step(step, input, ctx),
            PROTOCOL_LENDING => execute_lending_step(step, input, ctx),
            PROTOCOL_CDP => execute_cdp_step(step, input, ctx),
            PROTOCOL_PERP => execute_perp_step(step, input, ctx),
            _ => abort 0,
        }
    }
}
```

## 跨协议套利的风险放大

| 风险 | 单协议 | 跨协议 |
|------|--------|--------|
| 滑点 | 单次 | 多次叠加 |
| Gas | 低 | 高（多步操作） |
| 执行风险 | 低 | 高（中间步骤可能失败） |
| 协议风险 | 单一 | 多个协议的联合风险 |
| 时间风险 | 低 | 高（跨区块执行时价格可能变化） |

跨协议套利的利润通常更高，但风险也成倍增加。每个额外步骤都增加执行失败的概率。
