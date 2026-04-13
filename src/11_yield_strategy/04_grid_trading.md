# 11.4 网格交易

## 网格交易的本质

网格交易（Grid Trading）是自动化做市的最简单形式：

```
在价格区间内设置 N 个价格网格线
  → 在每条网格线下方挂买单
  → 在每条网格线上方挂卖单
  → 价格每穿过一条网格线就触发一次买卖
  → 每次买卖赚取一个网格间距的利润
```

```
价格轴（SUI/USDC）：

  $1.40 ─── 卖出 ─── (网格线 7)
  $1.35 ─── 卖出 ─── (网格线 6)
  $1.30 ─── 卖出 ─── (网格线 5)  ← 当前价
  $1.25 ─── 买入 ─── (网格线 4)
  $1.20 ─── 买入 ─── (网格线 3)
  $1.15 ─── 买入 ─── (网格线 2)
  $1.10 ─── 买入 ─── (网格线 1)

价格从 $1.30 跌到 $1.25：触发买入
价格从 $1.25 涨回 $1.30：触发卖出，赚 $0.05 差价
```

## 网格参数设计

### 关键参数

```
上限价格（upper）：网格的最高价格
下限价格（lower）：网格的最低价格
网格数量（grids）：网格线的数量
每格投入（per_grid）：每条网格线的资金量

推导参数：
  网格间距 = (upper - lower) / grids
  单格利润率 = 网格间距 / 当前价
  总投入 = per_grid × grids × 2（需要双边资金）
```

### 参数选择的权衡

```
网格数量多（间距小）：
  ✓ 交易频率高，捕捉小波动
  ✗ 每笔利润小
  ✗ Gas 成本高

网格数量少（间距大）：
  ✓ 每笔利润大
  ✓ Gas 成本低
  ✗ 可能错过小波动
  ✗ 价格超出区间后网格停止工作
```

## 完整 Move 实现

```move
module yield_strategy::grid_trading;
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;

    #[error]
    const ENotOwner: vector<u8> = b"Not Owner";
    #[error]
    const EInvalidParams: vector<u8> = b"Invalid Params";
    #[error]
    const EInsufficientBalance: vector<u8> = b"Insufficient Balance";
    #[error]
    const EPriceOutOfRange: vector<u8> = b"Price Out Of Range";
    #[error]
    const EGridNotTriggered: vector<u8> = b"Grid Not Triggered";
    const PRECISION: u64 = 1_000_000_000;

    public struct GridConfig has store {
        upper_price: u64,
        lower_price: u64,
        grid_count: u64,
        grid_spacing: u64,
        amount_per_grid: u64,
    }

    public struct GridState has store {
        active_grids: vector<bool>,
        filled_buys: u64,
        filled_sells: u64,
        total_profit: u64,
    }

    public struct GridBot has key {
        id: UID,
        config: GridConfig,
        state: GridState,
        base_balance: Balance<BaseCoin>,
        quote_balance: Balance<QuoteCoin>,
        last_price: u64,
        owner: address,
    }

    public struct GridFilled has copy, drop {
        grid_index: u64,
        side: String,
        price: u64,
        amount: u64,
    }

    public fun create<BaseCoin, QuoteCoin>(
        base: Coin<BaseCoin>,
        quote: Coin<QuoteCoin>,
        upper_price: u64,
        lower_price: u64,
        grid_count: u64,
        amount_per_grid: u64,
        initial_price: u64,
        ctx: &mut TxContext,
    ) {
        assert!(upper_price > lower_price, EInvalidParams);
        assert!(grid_count > 1, EInvalidParams);
        assert!(initial_price >= lower_price && initial_price <= upper_price, EInvalidParams);
        let spacing = (upper_price - lower_price) / grid_count;
        let mut active = vector::empty();
        let mut i = 0;
        while (i < grid_count) {
            let grid_price = lower_price + spacing * i;
            active.push_back(grid_price < initial_price);
            i = i + 1;
        };
        let bot = GridBot {
            id: object::new(ctx),
            config: GridConfig {
                upper_price,
                lower_price,
                grid_count,
                grid_spacing: spacing,
                amount_per_grid,
            },
            state: GridState {
                active_grids: active,
                filled_buys: 0,
                filled_sells: 0,
                total_profit: 0,
            },
            base_balance: coin::into_balance(base),
            quote_balance: coin::into_balance(quote),
            last_price: initial_price,
            owner: ctx.sender(),
        };
        transfer::share_object(bot);
    }

    public fun on_price_update(
        bot: &mut GridBot,
        new_price: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == bot.owner, ENotOwner);
        let mut i = 0;
        while (i < bot.config.grid_count) {
            let grid_price = bot.config.lower_price + bot.config.grid_spacing * (i + 1);
            if (bot.state.active_grids[i]) {
                if (new_price >= grid_price && bot.last_price < grid_price) {
                    let base_amount = bot.config.amount_per_grid;
                    if (balance::value(&bot.base_balance) >= base_amount) {
                        sell_grid(bot, i, base_amount, grid_price, ctx);
                    };
                    bot.state.active_grids[i] = false;
                };
            } else {
                if (new_price <= grid_price && bot.last_price > grid_price) {
                    let quote_needed = bot.config.amount_per_grid * grid_price / PRECISION;
                    if (balance::value(&bot.quote_balance) >= quote_needed) {
                        buy_grid(bot, i, quote_needed, grid_price, ctx);
                    };
                    bot.state.active_grids[i] = true;
                };
            };
            i = i + 1;
        };
        bot.last_price = new_price;
    }

    fun sell_grid(
        bot: &mut GridBot,
        grid_index: u64,
        base_amount: u64,
        grid_price: u64,
        ctx: &mut TxContext,
    ) {
        let base_coin = coin::take(&mut bot.base_balance, base_amount, ctx);
        let quote_value = base_amount * grid_price / PRECISION;
        bot.state.filled_sells = bot.state.filled_sells + 1;
        bot.state.total_profit = bot.state.total_profit + bot.config.grid_spacing * base_amount / PRECISION;
        event::emit(GridFilled {
            grid_index,
            side: string::utf8(b"sell"),
            price: grid_price,
            amount: base_amount,
        });
        coin::destroy_zero(base_coin);
    }

    fun buy_grid(
        bot: &mut GridBot,
        grid_index: u64,
        quote_amount: u64,
        grid_price: u64,
        ctx: &mut TxContext,
    ) {
        let quote_coin = coin::take(&mut bot.quote_balance, quote_amount, ctx);
        let base_amount = quote_amount * PRECISION / grid_price;
        bot.state.filled_buys = bot.state.filled_buys + 1;
        event::emit(GridFilled {
            grid_index,
            side: string::utf8(b"buy"),
            price: grid_price,
            amount: base_amount,
        });
        coin::destroy_zero(quote_coin);
    }

    public fun grid_profit(bot: &GridBot): u64 {
        bot.state.total_profit
    }

    public fun grid_stats(bot: &GridBot): (u64, u64, u64) {
        (bot.state.filled_buys, bot.state.filled_sells, bot.state.total_profit)
    }

    public fun withdraw<BaseCoin, QuoteCoin>(
        bot: &mut GridBot,
        base_amount: u64,
        quote_amount: u64,
        ctx: &mut TxContext,
    ): (Coin<BaseCoin>, Coin<QuoteCoin>) {
        assert!(ctx.sender() == bot.owner, ENotOwner);
        let base = coin::take(&mut bot.base_balance, base_amount, ctx);
        let quote = coin::take(&mut bot.quote_balance, quote_amount, ctx);
        (base, quote)
    }
```

## 网格交易的收益估算

```
假设：
  价格区间：$1.00 - $1.40
  网格数：8
  网格间距：$0.05
  每格投入：100 SUI
  总投入：1600 SUI（800 用于买入，800 保留用于卖出）

每月价格穿越网格次数：~120 次
每次利润：$0.05 × 100 = $5
月利润：120 × $5 = $600
月收益率：$600 / $1600 ≈ 37.5%

但这假设价格在区间内来回震荡。
```

## 网格失效的场景

```
1. 单边上涨：所有买单成交，卖出全部持仓后踏空
2. 单边下跌：所有卖单成交后，持仓全部缩水
3. 区间外横盘：价格在区间外停留，网格不工作
4. 超高波动：价格在几秒内穿越多个网格，来不及成交
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 单边行情 | 价格单方向突破区间，网格停止工作且持有单边资产 |
| 资金效率 | 部分资金长期闲置（远离当前价的网格不会触发） |
| Gas 成本 | 每次网格触发需要一笔交易，Sui gas 低但不是零 |
| 滑点 | 实际成交价可能偏离网格价 |
| 延迟 | 链上价格更新有延迟，可能错过最优成交点 |
