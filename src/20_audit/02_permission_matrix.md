# 20.2 权限矩阵与高风险函数识别

## 权限矩阵模板

| 操作       | 普通用户 | LP  | 清算者 | 管理员 | 紧急管理员 |
| ---------- | -------- | --- | ------ | ------ | ---------- |
| 存款       | ✅       | ✅  | ✅     | ✅     | ❌         |
| 取款       | ✅       | ✅  | ✅     | ✅     | ❌         |
| 借款       | ✅       | ✅  | ✅     | ✅     | ❌         |
| 偿还       | ✅       | ✅  | ✅     | ✅     | ❌         |
| 清算       | ❌       | ❌  | ✅     | ❌     | ❌         |
| 调整参数   | ❌       | ❌  | ❌     | ✅     | ❌         |
| 暂停       | ❌       | ❌  | ❌     | ✅     | ✅         |
| 恢复       | ❌       | ❌  | ❌     | ✅     | ❌         |
| 提取手续费 | ❌       | ❌  | ❌     | ✅     | ❌         |
| 升级合约   | ❌       | ❌  | ❌     | ✅     | ❌         |

## 高风险函数清单

### 资产转移函数

所有涉及代币转入/转出的函数：

```move
public fun deposit(...)       // 代币进入协议
public fun withdraw(...)      // 代币离开协议
public fun borrow(...)        // 代币离开协议
public fun repay(...)         // 代币进入协议
public fun liquidate(...)     // 代币双向转移
public fun claim_interest(...) // 代币离开协议
```

审计重点：

- 是否可以无抵押取款？
- 是否可以重复领取利息？
- 清算金额计算是否正确？

### 状态修改函数

所有修改协议全局状态的函数：

```move
public fun update_parameters(...)  // 修改风险参数
public fun set_interest_rate(...)  // 修改利率
public fun update_oracle(...)      // 修改预言机地址
public fun pause(...)              // 暂停协议
public fun unpause(...)            // 恢复协议
```

审计重点：

- 谁可以调用？（权限检查）
- 修改是否立即生效？（时间锁）
- 修改是否被记录？（事件）

### 计算函数

所有涉及金额计算的函数：

```move
fun calculate_shares(...)        // 份额计算
fun calculate_interest(...)      // 利息计算
fun calculate_health_factor(...) // 健康因子计算
fun calculate_liquidation(...)   // 清算金额计算
fun get_amount_out(...)          // AMM 输出计算
```

审计重点：

- 是否有溢出风险？
- 是否有除零风险？
- 精度是否足够？
- 是否与白皮书公式一致？

## 攻击树分析

对每个高风险函数，构建攻击树——"攻击者如何利用这个函数获利？"

### 示例：`withdraw` 的攻击树

```
目标：无抵押提取资金
├── 路径 1：绕过健康因子检查
│   ├── 在同一交易中先 borrow 再 withdraw（重入）
│   ├── 使用过期的预言机价格
│   └── 利用精度截断使健康因子计算偏高
├── 路径 2：伪造权限
│   ├── 使用他人的 Position 对象
│   └── 利用 transfer 机制的边界条件
└── 路径 3：操纵外部依赖
    ├── 操纵预言机价格
    └── 利用代币回调（Move 中不可能，但需文档说明）
```

### 示例：`liquidate` 的攻击树

```
目标：恶意清算或清算套利
├── 路径 1：触发不必要的清算
│   ├── 操纵预言机使健康因子看起来偏低
│   └── 在清算前大量存入拉低价格
├── 路径 2：清算金额计算偏差
│   ├── 利用精度截断多获取抵押品
│   └── 部分清算的金额边界条件
└── 路径 3：清算者抢跑
    └── 通过 mempool 监控待处理清算
```

审计师会根据攻击树逐条验证：每个攻击路径是否有对应的防御措施（代码检查、事件监控、参数约束）。

## Move 特有的审计要点

### 对象权限

Move 的对象模型提供了天然的权限边界，但需要检查：

```move
// 正确：只有持有 Position 的用户才能操作
public fun withdraw(position: &mut Position, ...): Coin<SUI> { ... }

// 危险：任何人都能调用，需要内部权限检查
public fun withdraw(pool: &mut Pool, user: address, ...): Coin<SUI> {
    // 必须验证调用者是 user 或有授权
}
```

### Capability 模式验证

```move
// AdminCap 应该只在 init 中创建，转移给多签
public struct AdminCap has key, store { id: UID }

// 审计检查：
// 1. AdminCap 是否被正确冻结或转移
// 2. 所有使用 AdminCap 的函数是否记录事件
// 3. AdminCap 是否可以被意外 drop
```

### 泛型安全

```move
// 审计检查：泛型参数是否有约束
public fun deposit<T>(pool: &mut Pool<T>, coin: Coin<T>, ...) { ... }

// 问题：如果 T 是恶意代币合约，coin::value() 可能返回错误值
// 防御：使用白名单约束 T 的类型
```
