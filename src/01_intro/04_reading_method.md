## 1.4 本书的路线图与阅读方法

### 六篇结构

全书分为六篇，按依赖关系排列：

| 篇 | 主题 | 核心 |
|----|------|------|
| 第一篇 | 认知地基 | 对象模型、Move 精要、DeFi 抽象、风险语言 |
| 第二篇 | 价格基础设施 | DEX（AMM + 集中流动性 + 订单簿）、预言机、聚合器 |
| 第三篇 | 信用与货币 | 借贷、流动性挖矿、CDP、稳定币 |
| 第四篇 | 收益与杠杆 | LSD、做市策略、衍生品、现货杠杆、套利、Launchpad、跨链与保险 |
| 第五篇 | 警惕 | 攻击模式、协议工程、审计准备 |
| 附录 | 工具箱 | 术语表、公式、CLI、延展阅读、代码索引 |

依赖关系是严格线性的：第二篇需要第一篇的基础，第三篇需要第二篇的价格基础设施，第四篇需要第三篇的信用层，第五篇贯穿所有协议类型。

### 每章的统一分析方法

从第二篇开始，每一章分析具体协议时，我们都遵循同一套步骤：

**第一步：业务问题** — 这个协议解决什么问题？为什么市场需要它？

**第二步：资产流** — 资产从用户流入协议，在协议内部如何流转？哪些路径可以提取？

**第三步：对象设计** — 在 Sui 上，核心状态如何用对象表达？Owned vs Shared 的选择依据是什么？

**第四步：风险分析** — 用五问法识别关键风险。重点分析价格依赖、清算机制、权限边界。

以 DEX 为例：

```move
module defi_book::amm_example {
    use sui::coin::{Self, Coin};

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        reserve_a: Coin<A>,
        reserve_b: Coin<B>,
        fee_bps: u64,
    }

    public struct LPReceipt has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
    }

    public entry fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        ctx: &mut TxContext,
): LPReceipt {
        let shares = coin_a.value(&coin_a);
        coin::join(&mut pool.reserve_a, coin_a);
        coin::join(&mut pool.reserve_b, coin_b);
        LPReceipt {
            id: object::new(ctx),
            pool_id: object::id(pool),
            shares,
        }
    }
}
```

对这段代码的四步分析：

- **业务问题**：提供两种资产之间的自动兑换
- **资产流**：用户存入两种代币 → 进入储备池 → 获得 LPReceipt → 凭证可赎回
- **对象设计**：Pool 是 Shared Object（多人交互），LPReceipt 是 Owned Object（个人持有）
- **风险分析**：价格由储备量比值决定（AMM 内生价格），无常损失是 LP 的主要风险

### 如何使用本书的代码示例

本书所有 Move 代码都可以在本地运行测试。环境配置参见附录C。基本流程：

```bash
# 创建新的 Move 包
sui move new defi_book_examples

# 将代码片段放入 sources/ 目录
# 编辑 Move.toml 添加依赖

# 编译
sui move build

# 运行测试
sui move test
```

建议在每个章节结束时，将代码示例复制到本地项目并运行测试。修改参数观察行为变化，这是建立直觉最快的方式。

> 风险提示：本书的代码示例是教学代码，有意简化了边界检查、溢出保护和错误处理。不要将示例代码直接用于生产环境。第三篇和第五篇会专门讨论从教学原型到生产代码的转换过程。
