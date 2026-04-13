# 9.2 法币抵押稳定币：储备、托管与链上表示

## 机制轮廓

**法币抵押稳定币**的叙事最简单：发行方在链下持有美元或高流动性美元等价物，链上代币作为**可赎回债权**的凭证。用户信任的是：

1. **储备真实存在**（数量与资产类别）
2. **赎回通道有效**（合规前提下兑回法币或等价物）
3. **发行方不会滥发或冻结**（治理与合规风险）

链上合约通常**不负责**验证银行账户——那是审计、监管与链下披露的领域。链上呈现为：**谁持有 `TreasuryCap`，谁就能在规则允许下增加或减少代币供给**。

## 中心化与审查维度

| 风险 | 说明 |
|------|------|
| 储备透明度 | 是否定期披露、是否由第三方审计 |
| 对手方风险 | 发行方违约、挪用储备 |
| 审查与冻结 | 合规地址可能被限制转账（与「公链无许可」叙事存在张力） |
| 银行体系风险 | 储备存放银行的信用风险 |

这些风险**无法**仅靠 Move 代码消除，只能通过治理、监管与披露缓释。

## 链上最小模型：受控铸销

在 Sui 上，法币抵押型资产通常表现为标准 `Coin<T>`，由发行方控制的 `TreasuryCap` 铸造与销毁。本书在 `src/09_cdp/code/fiat_stablecoin_sketch/` 提供**极简教学包**：

- 模块 **`fiat_stablecoin_sketch::fiat`**
- **`FiatTreasury`**：共享对象，内含 `TreasuryCap<FIAT>`
- **`IssuerCap`**：发行方能力对象，持有者可调用 `issuer_mint` / `issuer_burn`

核心逻辑（节选）：

```move
module fiat_stablecoin_sketch::fiat;
    // ...
    public struct FiatTreasury has key {
        id: UID,
        cap: TreasuryCap<FIAT>,
    }

    public fun issuer_mint(
        _: &IssuerCap,
        treasury: &mut FiatTreasury,
        to: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let c = coin::mint(&mut treasury.cap, amount, ctx);
        transfer::public_transfer(c, to);
    }

    public fun issuer_burn(_: &IssuerCap, treasury: &mut FiatTreasury, c: Coin<FIAT>) {
        coin::burn(&mut treasury.cap, c);
    }
```

### 这段代码在教什么

1. **链上稳定 ≠ 去中心化**：`IssuerCap` 是明确的能力边界——与真实世界中的「发行部门」同构。
2. **铸销权限与储备披露是分离的**：Move **不会**自动检查链下是否真有美元；审计与合规在链外完成。
3. **可组合性**：对用户与其他 DeFi 协议而言，`Coin<FIAT>` 与任意其他代币一样可转账、进池子、做抵押——**风险在发行方与监管，不在 AMM 数学**。

## 与 CDP、算法币的对照

- **法币抵押**：信任半径在**发行方与监管**；链上逻辑可以极薄。
- **CDP**：信任半径在**合约 + 预言机 + 清算市场**；链上逻辑厚，但抵押品透明。
- **算法**：信任半径在**规则能否在长期压力下成立**；历史上失败案例多。

下一节讨论这些代币在 **Sui** 上如何落地（原生 USDC、桥、合规注意点）。
