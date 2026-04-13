# 7.28 价格预言机接口设计

借贷协议必须知道资产价格。本节设计预言机接口规范。

## 为什么需要预言机

```
lending_market 使用 1:1 价格假设（教学简化）
生产环境必须使用预言机:

  抵押 1000 SUI，借出 1200 USDC
  → SUI 可能值 $2 → HF = 2000×80%/1200 = 1.33 安全
  → SUI 可能值 $0.50 → HF = 500×80%/1200 = 0.33 应清算

  没有价格 → 无法正确计算 HF → 系统不安全
```

## 接口设计

```move
public struct Price has copy, drop, store {
    price: u64,           // 价格（精度 10^8）
    confidence: u64,      // 置信度（BPS）
    timestamp: u64,       // 价格时间戳
    decimals: u8,
}

public fun get_price(oracle: &Oracle, asset: TypeName): Price {
    let feed = bag::borrow<PriceFeed>(&oracle.feeds, asset);
    assert!(feed.is_fresh(), EStalePrice);
    Price { price: feed.price, confidence: feed.confidence, ... }
}
```

## 价格在 HF 中的应用

```
生产级 HF:
  collateral_value = collateral × collateral_price
  debt_value = debt × debt_price
  HF = collateral_value × threshold / debt_value

  1000 SUI × $2.00 = $2000
  1200 USDC × $1.00 = $1200
  HF = 2000 × 80% / 1200 = 1.33
```

## Sui 上的预言机

```
Pyth Network: Pull 模式，高频，置信区间
Supra Oracle: Push 模式，DORA 聚合
Switchboard: 多数据源聚合

推荐: Pyth + PTB 集成
  PTB:
    1. 提交 Pyth 价格更新
    2. 使用最新价格执行借贷操作
```

## 安全要求

```
1. 新鲜度: 价格 < 60 秒
2. 偏差限制: 单次变动不超过阈值
3. 置信度: 低置信度时降低 LTV
4. 回退: 主预言机失效时的备用
5. 紧急暂停: 预言机异常时暂停协议
```

## 总结

```
预言机接口: get_price(asset) → Price
安全: 新鲜度、偏差、置信度、回退
Sui 推荐: Pyth Pull + PTB
```
