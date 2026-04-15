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
