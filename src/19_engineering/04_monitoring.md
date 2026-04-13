# 19.4 监控、告警与事件响应

## 最低监控信号集

| 信号 | 触发条件 | 响应 |
|------|----------|------|
| 预言机价格过期 | 价格超过 N 分钟未更新 | 暂停依赖价格的操作 |
| 资金利用率异常 | 利用率 > 95% 持续 > 10 分钟 | 检查是否有异常借款 |
| 清算堆积 | 待清算仓位数 > 阈值 | 提高清算激励 |
| 大额异常交易 | 单笔交易 > TVL 的 5% | 检查是否为攻击 |
| AdminCap 转移 | AdminCap 被转移 | 确认是否授权操作 |
| 合约升级 | 检测到 upgrade 交易 | 确认是否为计划内升级 |

## 事件驱动监控

```move
public struct AlertEvent has copy, drop {
    alert_type: u8,
    severity: u8,
    pool_id: ID,
    message: vector<u8>,
    timestamp: u64,
}

public fun emit_alert(
    alert_type: u8,
    severity: u8,
    pool_id: ID,
    message: vector<u8>,
) {
    sui::event::emit(AlertEvent {
        alert_type,
        severity,
        pool_id,
        message,
        timestamp: sui::clock::timestamp_ms(sui::clock::create_for_testing()),
    });
}
```

## 紧急响应流程

```
检测到异常
  │
  ├── 1. 确认：是真异常还是误报？
  │
  ├── 2. 评估：影响范围和严重程度
  │
  ├── 3. 决策：
  │   ├── 3a. 低风险 → 监控，不做操作
  │   ├── 3b. 中风险 → 暂停特定操作
  │   └── 3c. 高风险 → 全局暂停
  │
  ├── 4. 执行：通过多签操作暂停/调整参数
  │
  ├── 5. 通知：社区公告 + 事件详情
  │
  ├── 6. 修复：分析根因，制定修复方案
  │
  └── 7. 恢复：验证修复后恢复操作
```

## 预上线检查清单

- [ ] 所有合约在测试网通过完整测试套件
- [ ] 完成至少一次外部审计
- [ ] AdminCap 已转移到多签地址（至少 3/5）
- [ ] 所有参数已在测试网验证
- [ ] 预言机集成在测试网验证
- [ ] 紧急暂停机制在测试网验证
- [ ] 监控系统已部署并测试
- [ ] 紧急响应流程已文档化
- [ ] 团队成员已演练紧急响应流程
- [ ] 社区公告已准备就绪
