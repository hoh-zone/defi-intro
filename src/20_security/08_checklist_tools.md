# 20.8 Move 安全检查清单与工具链

## 安全检查清单

以下清单按优先级排列。每个 DeFi 协议上线前必须完成所有项目。

### 一、资金安全（P0 — 必须零缺陷）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 1 | 每条存取路径都有 roundtrip 测试 | 单元测试：存入 N → 取出 N |
| 2 | Coin/Balance 不存在未处理的值 | 编译器保证（线性类型） |
| 3 | 所有算术使用 u256 中间精度 | grep `* /` 检查 |
| 4 | 先乘后除（不先除后乘） | 代码审查 |
| 5 | 金额范围检查（min/max） | assert 检查 |
| 6 | 累加器精度足够 | 测试：小额长期累加 |

### 二、权限安全（P0 — 必须零缺陷）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 7 | 所有 shared 对象入口函数有鉴权 | 逐一审查函数签名 |
| 8 | Admin/Oper Capability 分离 | 架构审查 |
| 9 | Capability 没有 drop ability | struct 定义检查 |
| 10 | 关键 Capability 在多签地址 | 链上验证 |
| 11 | UpgradeCap 在高门槛多签 | 部署验证 |

### 三、预言机安全（P1 — 高优先级）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 12 | 价格有新鲜度检查 | 时间戳验证 |
| 13 | 价格有偏离检查 | 与预期范围比较 |
| 14 | 多预言机聚合有仲裁逻辑 | 代码审查 |
| 15 | 预言机失效时有降级方案 | 场景测试 |

### 四、清算与风控（P1 — 高优先级）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 16 | 健康因子计算正确 | 边界值测试 |
| 17 | 清算在极端价格下仍能执行 | 压力测试 |
| 18 | 清算激励足够覆盖 gas | 模拟计算 |
| 19 | 级联清算有熔断机制 | 场景测试 |

### 五、升级与治理（P1 — 高优先级）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 20 | 升级策略为 compatible 或 additive | Move.toml 检查 |
| 21 | 升级有版本号记录 | 事件验证 |
| 22 | 关键参数变更有时间锁 | 流程审查 |
| 23 | 紧急暂停可分级触发 | 功能测试 |
| 24 | 恢复暂停的门槛 > 暂停的门槛 | 权限设计审查 |

### 六、DoS 防护（P2 — 中优先级）

| # | 检查项 | 验证方法 |
|---|--------|----------|
| 25 | 共享对象无无限循环 | 静态分析 |
| 26 | 向量操作有上限 | 参数检查 |
| 27 | 动态字段代替大向量 | 架构审查 |
| 28 | Gas 消耗在合理范围 | 基准测试 |

## Sui CLI 安全检查

```bash
# 验证构建无错误
sui move build

# 运行所有测试
sui move test

# 运行测试并显示覆盖率
sui move test --coverage

# 检查升级兼容性
sui client verify-upgrade \
  --package-path . \
  --upgrade-capability <UPGRADE_CAP_ID>

# 查看包的依赖关系
sui client list-dependencies --package <PACKAGE_ID>
```

### 自动化测试脚本

```bash
#!/bin/bash
set -e

echo "=== Building ==="
sui move build

echo "=== Running tests ==="
sui move test

echo "=== Checking for common issues ==="

# 检查是否有未使用的 AdminCap
echo "Checking for orphaned capabilities..."

# 检查是否有硬编码地址
grep -rn "0x0000" sources/ && echo "WARNING: hardcoded addresses found"

# 检查是否有 assert! 与 0 错误码
grep -rn "assert!.*,\s*0)" sources/ && echo "WARNING: zero error codes found"

echo "=== All checks passed ==="
```

## Move Prover

Move Prover 是 Move 的形式化验证工具。它可以用逻辑规约（specification）证明代码满足特定性质：

```move
module defi::prover_example {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;

    public struct Vault has key {
        id: UID,
        balance: Coin<SUI>,
    }

    public fun deposit(vault: &mut Vault, coin: Coin<SUI>) {
        coin::join(&mut vault.balance, coin);
    }

    public fun withdraw(
        vault: &mut Vault,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        coin::take(&mut vault.balance, amount, ctx)
    }

    #[spec(prove)]
    spec deposit {
        let pre_balance = coin::value(balance(vault));
        let deposit_amount = coin::value(coin);
        ensures coin::value(balance(vault)) == pre_balance + deposit_amount;
    }
}
```

### 运行 Prover

```bash
# 安装 Prover（需要 z3 和 boogie）
sui move prove

# 只验证特定模块
sui move prove --module defi::prover_example
```

### Prover 的适用场景

| 场景 | 推荐程度 | 说明 |
|------|----------|------|
| 核心资金操作 | 强烈推荐 | 存取款的金额守恒 |
| 数学公式正确性 | 推荐 | AMM invariant、利率计算 |
| 权限不变量 | 推荐 | "只有 AdminCap 持有者能调参" |
| 复杂状态机 | 可选 | Launchpad 状态转换 |
| 简单 getter | 不需要 | 成本高于收益 |

## 静态分析工具

### 自定义 Lint 规则

以下 Python 脚本检查常见的 Move 安全问题：

```python
#!/usr/bin/env python3
"""Move 安全 lint 工具"""
import re
import sys
from pathlib import Path

def check_file(filepath: Path) -> list[str]:
    issues = []
    content = filepath.read_text()
    lines = content.split('\n')

    for i, line in enumerate(lines, 1):
        # 检查先除后乘
        if re.search(r'/\s*\w+\s*\*', line):
            issues.append(f"{filepath}:{i}: 除法后乘法，可能精度丢失")

        # 检查零错误码
        if re.search(r'assert!.*,\s*0\s*\)', line):
            issues.append(f"{filepath}:{i}: 错误码为 0，应使用命名常量")

        # 检查硬编码地址
        if re.search(r'@0x[0-9a-fA-F]{4,}', line):
            issues.append(f"{filepath}:{i}: 硬编码地址")

        # 检查 shared 对象入口函数无鉴权
        if re.search(r'public\s+fun\s+\w+\s*\([^)]*\&mut\s+\w+', line):
            if 'AdminCap' not in content and 'Cap' not in line:
                pass

    return issues

def main():
    src_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('sources')
    all_issues = []
    for f in src_dir.rglob('*.move'):
        all_issues.extend(check_file(f))

    for issue in all_issues:
        print(issue)

    if all_issues:
        sys.exit(1)
    else:
        print("No issues found")

if __name__ == '__main__':
    main()
```

## 上线前安全流程

```
┌──────────────────────────────────────────────┐
│  Phase 1: 内部审查（开发团队）                 │
│  □ 完成安全清单全部项目                        │
│  □ 测试覆盖率 > 90%                          │
│  □ 所有 P0 问题已关闭                         │
│  □ Move Prover 验证核心模块                   │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│  Phase 2: 外部审计                            │
│  □ 选择审计公司                               │
│  □ 提交完整文档 + 测试 + 部署脚本             │
│  □ 审计周期 2-6 周                            │
│  □ 修复所有 Critical / High 问题              │
│  □ Medium 问题有明确的处理计划                 │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│  Phase 3: 测试网验证                          │
│  □ 在测试网部署完整流程                        │
│  □ 模拟极端场景（价格暴跌、级联清算）          │
│  □ 社区测试（bug bounty 可选）                │
│  □ 多签设置并验证                             │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│  Phase 4: 主网部署                            │
│  □ 限制初始 TVL 上限                          │
│  □ 逐步开放功能（先存款 → 再借款 → 再杠杆）    │
│  □ 实时监控就绪                               │
│  □ 紧急响应团队待命                           │
│  □ UpgradeCap 转入多签                        │
└──────────────────────────────────────────────┘
```

## 小结

安全不是一次性的检查，而是持续的过程。清单保证不遗漏已知问题，工具链自动化可机械验证的部分，外部审计提供独立的专业视角。将安全检查内嵌到开发流程的每一步，而不是在上线前才想起——这就是"从入门到警惕"的最终落地。
