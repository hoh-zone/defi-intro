# 5.8 预言机失效模式与攻击场景

## 四种预言机失效模式

### 失效 1：延迟失效（Stale Price）

```
场景：预言机价格 5 分钟没有更新，但市场已经暴跌 30%

影响：
  借贷协议以为抵押品仍然值 $1000（实际值 $700）
  → 借款人过度借贷
  → 协议产生坏账

防护：
  设置 max_staleness 参数
  如果价格超过 N 秒未更新，拒绝操作
```

### 失效 2：操纵攻击（Manipulation）

```
场景：攻击者通过闪电贷在 AMM 池中砸盘，操纵 TWAP 价格

步骤：
  1. 闪电贷借入大量 ETH
  2. 在 DEX 中卖出 ETH，压低价格
  3. 利用低价在借贷协议中触发清算或低价购买
  4. 归还闪电贷，获利

历史案例：
  bZx 攻击（2020）— $1M 损失
  利用 Kyber 和 Uniswap 的价格差异
```

### 失效 3：停滞失效（Stuck Price）

```
场景：预言机节点全部离线，价格永远不变

影响：
  协议继续使用过时的价格
  如果市场已经大幅波动，协议资金面临风险

防护：
  监控预言机更新频率
  设置 fallback 预言机
```

### 失效 4：多源冲突（Source Divergence）

```
场景：两个预言机对同一资产给出相差 >5% 的价格

影响：
  如果协议只读取一个预言机，可能使用错误价格
  如果协议读取多个预言机，需要仲裁逻辑

防护：
  多预言机交叉验证
  设置最大偏差阈值
```

## 经典攻击案例分析

### 案例 1：Venus Protocol（2021）

```
攻击向量：操纵 Band Protocol 预言机价格
结果：$200M 级别的异常清算

原因：
  Band Protocol 使用单一数据源
  价格更新频率低
  没有偏差检查

教训：
  使用多源预言机
  设置价格偏差阈值
  清算需要额外的时间延迟
```

### 案例 2：Mango Markets（2022）

```
攻击向量：操纵预言机价格 → 虚假抵押品价值
结果：$114M 损失

步骤：
  1. 攻击者在 Mango 上开大量永续合约多单
  2. 同时在现货市场买入 MNGO 代币推高价格
  3. 预言机反映 MNGO 高价
  4. 攻击者的 MNGO 抵押品"值"很多钱
  5. 借出协议中所有其他资产

教训：
  低流动性资产的预言机价格不可靠
  需要设置抵押品上限
  预言机价格 + TWAP 双重验证
```

### 用 Move 实现攻击模拟

```move
module oracle::attack_simulation;

public struct AttackVector has store {
    attack_type: u8,
    profit_potential: u64,
    difficulty: u8,
    detection_likelihood: u8,
}

public fun assess_oracle_risk(
    uses_single_source: bool,
    update_frequency_ms: u64,
    has_deviation_check: bool,
    has_staleness_check: bool,
    asset_liquidity_usd: u64,
): vector<AttackVector> {
    let mut risks = vector::empty();
    if (uses_single_source) {
        risks.push_back(AttackVector {
            attack_type: 1,
            profit_potential: 100000,
            difficulty: 2,
            detection_likelihood: 3,
        });
    };
    if (update_frequency_ms > 60_000) {
        risks.push_back(AttackVector {
            attack_type: 2,
            profit_potential: 50000,
            difficulty: 1,
            detection_likelihood: 5,
        });
    };
    if (!has_deviation_check) {
        risks.push_back(AttackVector {
            attack_type: 3,
            profit_potential: 200000,
            difficulty: 3,
            detection_likelihood: 2,
        });
    };
    if (asset_liquidity_usd < 1_000_000) {
        risks.push_back(AttackVector {
            attack_type: 4,
            profit_potential: 500000,
            difficulty: 2,
            detection_likelihood: 1,
        });
    };
    risks
}
```

## 攻击成本估算

```
操纵 AMM TWAP 的成本：

时间窗口 T 内操纵价格到 P_manipulated：
  需要的资本 ≈ pool_liquidity × |P_manipulated - P_real| / P_real × T

示例：
  池子流动性：$10M
  目标偏差：10%
  时间窗口：1 小时

  操纵成本 ≈ $10M × 0.1 × (1/24) ≈ $41,667
  如果攻击者能获利 > $41,667 → 攻击可行

防护：
  增大池子流动性
  缩短 TWAP 窗口
  使用外部预言机而非 AMM 价格
```

## 风险分析

| 失效模式 | 检测难度           | 防护成本                 | 影响范围   |
| -------- | ------------------ | ------------------------ | ---------- |
| 延迟失效 | 低（可检测）       | 低（加 staleness check） | 单协议     |
| 操纵攻击 | 中（实时难检测）   | 高（多预言机 + TWAP）    | 跨协议     |
| 停滞失效 | 低（可检测）       | 中（fallback 预言机）    | 单协议     |
| 多源冲突 | 中（需要仲裁逻辑） | 中（聚合算法）           | 取决于协议 |
