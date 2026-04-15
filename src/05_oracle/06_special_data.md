# 5.6 其他 Sui 预言机与特色数据

## 超越价格：链上数据的多样性

预言机不只是价格。任何链外信息都可以通过预言机传递到链上：

```
数据类型          依赖它的协议              主要提供者
─────────────────────────────────────────────────
资产价格          借贷、衍生品、CDP          Pyth/Supra/Switchboard
随机数            游戏、NFT 抽奖、抽奖       Pyth Entropy/Supra VRF
天气数据          天气保险、农业 DeFi        Switchboard 自定义
体育赛果          预测市场                   Switchboard/API3
汇率              跨境支付                   Pyth
商品价格          合成资产                   Pyth
选举结果          预测市场                   UMA/自定义
链上计算结果      任何需要复杂计算的协议     链下计算预言机
```

## Pyth 的 40+ 资产类别

Pyth 不只提供加密货币价格：

```
外汇（FX）：
  EUR/USD, GBP/USD, USD/JPY, ...
  → 用于跨境支付协议、合成外汇

大宗商品：
  XAU/USD（黄金）, XAG/USD（白银）, WTI 原油
  → 用于合成商品代币

股票/指数：
  AAPL, TSLA, SPX（标普 500）, ...
  → 用于合成股票协议

加密货币：
  BTC/USD, ETH/USD, SUI/USD, ...
  → 用于所有 DeFi 协议
```

### 读取非加密货币价格的 Move 代码

```move
module defi::commodity_oracle;
    use sui::clock::Clock;
    use pyth::price_feed::PriceFeed;

    const GOLD_FEED_ID: address = @0xGOLD;
    const EUR_USD_FEED_ID: address = @0xEURUSD;

    public struct CommodityPrice has store {
        usd_price: u64,
        confidence: u64,
        timestamp_ms: u64,
    }

    public fun get_gold_price(
        feed: &PriceFeed,
        clock: &Clock,
    ): CommodityPrice {
        let (price, conf, ts, _) = pyth::price_feed::get_price(feed);
        assert!(clock.timestamp_ms() - ts < 300_000, 0);
        CommodityPrice { usd_price: price, confidence: conf, timestamp_ms: ts }
    }

    public fun get_exchange_rate(
        feed: &PriceFeed,
        clock: &Clock,
    ): u64 {
        let (price, _, ts, _) = pyth::price_feed::get_price(feed);
        assert!(clock.timestamp_ms() - ts < 300_000, 0);
        price
    }
```

## 天气预言机

天气数据是链上保险的核心输入：

```
用例：农业保险
  触发条件："某地区连续 30 天降雨量低于 X 毫米"
  数据源：气象站数据 → Switchboard Aggregator
  赔付：自动触发（参数型保险）

用例：旅游保险
  触发条件："目的地降雨量超过 Y 毫米/天"
  数据源：OpenWeather API → Switchboard Job
  赔付：自动触发

技术实现：
  1. Switchboard 创建天气数据聚合器
  2. Job 定义 API URL 和数据提取路径
  3. Oracle 队列定期获取数据
  4. 保险合约读取聚合结果
```

```move
module insurance::weather;

use sui::clock::Clock;

public struct WeatherData has store {
    rainfall_mm: u64,
    temperature_c: u64,
    timestamp_ms: u64,
}

public struct RainfallPolicy has store {
    threshold_mm: u64,
    duration_days: u64,
    consecutive_days_below: u64,
    triggered: bool,
}

public fun check_rainfall_trigger(policy: &mut RainfallPolicy, weather: &WeatherData): bool {
    if (weather.rainfall_mm < policy.threshold_mm) {
        policy.consecutive_days_below = policy.consecutive_days_below + 1;
    } else {
        policy.consecutive_days_below = 0;
    };
    if (policy.consecutive_days_below >= policy.duration_days) {
        policy.triggered = true;
    };
    policy.triggered
}
```

## 体育与事件预言机

```
体育赛果：
  数据源：ESPN API / 体育数据供应商
  实现：Switchboard Job 定义 API 和结果路径
  争议处理：结果需要 N 个独立源确认

选举结果：
  数据源：美联社 / 官方选举机构
  实现：UMA 乐观预言机（争议期 + 投票裁决）
  特点：需要人工裁决机制
```

## 如何评估非价格预言机的可信度

```
评估维度：

1. 数据源的权威性
   官方数据 > 第三方聚合 > 个人提交

2. 获取方式的可验证性
   HTTPS API（不可验证）< 签名数据（可验证）

3. 争议机制
   有裁决机制 > 无裁决机制

4. 历史准确率
   检查过去的数据点是否准确

5. 延迟容忍度
   体育赛果可以等几分钟，价格不能
```

## 风险分析

| 风险         | 描述                                   |
| ------------ | -------------------------------------- |
| API 可用性   | 外部 API 可能宕机或限流                |
| 数据格式变化 | API 返回格式变更导致解析失败           |
| 时区问题     | 天气和体育数据需要精确的时区处理       |
| 人为操纵     | 某些事件结果可能被操纵（如低级别比赛） |
