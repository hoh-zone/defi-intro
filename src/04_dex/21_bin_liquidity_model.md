# 4.21 Bin 流动性模型

DLMM 的核心是 Bin——一个离散价格点，独立存储两种代币。本节深入 Bin 的结构、Swap 如何穿越 Bin、以及 LP 如何与 Bin 交互。

## Bin 结构

```
┌──────────────────────────────────┐
│           Bin                    │
│  bin_id: 6931                    │
│  price: 2.0000                   │
│  amount_x: 5000 (SUI)           │
│  amount_y: 10000 (USDC)         │
│  total_shares: 100               │
│  fee_accumulated_x: ...          │
│  fee_accumulated_y: ...          │
└──────────────────────────────────┘

Bin ID 与价格:
  price = bin_step^bin_id

  bin_step | 精度  | 场景
  ─────────|───────|──────────
  1.0001   | 0.01% | 稳定币
  1.001    | 0.1%  | 主流对
  1.01     | 1%    | 高波动
```

## Active vs Inactive Bin

```
三种状态:
  X-only: 只含 X (被买空 Y)
  Active: 同时含 X 和 Y (当前价格)
  Y-only: 只含 Y (被买空 X)

状态转换:
  Swap Y 买 X → Active → Y-only (X 被买完)
  Swap X 买 Y → Active → X-only (Y 被买完)

价格轴上:
  Bin:  6928   6929   6930   6931   6932   6933
  价格: $1.997 $1.998 $1.999 $2.000 $2.001 $2.002
  状态: Y-only Y-only Active Active X-only X-only
                        ↑ Active Bin
```

## Swap 穿越 Bin

### 单 Bin 内兑换

```
Active Bin ($2.00): X=5000 SUI, Y=10000 USDC

Swap 500 USDC 买 SUI:  可买 = 500/2.00 = 250 SUI
结果: X=4750, Y=10500, 仍然 Active
```

### Bin 被耗尽 → 跨 Bin

```
Active Bin ($2.00): X=5000, Y=10000

Swap 10000 USDC 买 SUI:
  可买 = 5000 SUI (全部), 花费 = 10000 USDC
  Bin → Y-only, Active 移到 Bin 6930 ($1.999)
```

### 跨多 Bin 的 Swap

```
初始:
  Bin 6929 ($1.998): X=3000, Y=0      X-only
  Bin 6930 ($1.999): X=4000, Y=8000   Active ←
  Bin 6931 ($2.000): X=5000, Y=10000  Active

Swap 20000 USDC 买 SUI (价格下降方向):

Step 1: Bin 6930 → 买 4000 SUI, 花费 7996 USDC
        Bin 6930 → Y-only, Active → 6929
Step 2: Bin 6929 → 买 3000 SUI, 花费 5994 USDC
        Bin 6929 → Y-only, Active → 6928
Step 3: Bin 6928 无流动性 → 停止
        返还 6010 USDC

总计: 买入 7000 SUI, 平均价 ≈ $1.999
```

## LP 存入 Bin

```
LP 向 Active Bin ($2.00) 存入 $2000:
  price = 2.00 → 500 SUI + 1000 USDC
  获得 Bin LP Share

LP 向 X-only Bin ($2.01) 存入:
  只需存 SUI (只有 X 端)
  存入 500 SUI, 获得 Share

LP 向 Y-only Bin ($1.99) 存入:
  只需存 USDC (只有 Y 端)
  存入 1000 USDC, 获得 Share
```

## 费用分配

```
Swap 经过 Bin 6931:
  输入 1000 USDC, 费率 0.3%, 手续费 = 3 USDC
  protocol_fee = 0.3 USDC
  lp_fee = 2.7 USDC → 按 share 比例分给该 Bin 的 LP

跨 Bin 费用各自独立:
  Bin 6931: 消耗 3000 USDC → fee 9 USDC
  Bin 6930: 消耗 5000 USDC → fee 15 USDC
  每个 Bin 的 LP 只赚自己 Bin 的费用
```

## 5-Bin DLMM 数值示例

```
初始 (均匀分布 $2000/Bin):
  Bin 6929-6933, 价格 $1.998-$2.002, 每个 X≈1000 Y≈2000

Swap 1: 用 1000 USDC 买 SUI
  Bin 6931: 买 500 SUI, X=500 Y=3000, 仍 Active

Swap 2: 用 3000 USDC 买 SUI
  Bin 6931: 买 500 SUI (耗尽), 花费 1000 → Y-only
  Bin 6930: 买 1000.5 SUI (耗尽), 花费 1999 → Y-only
  总计: 1500.5 SUI, 平均 ≈ $1.999
```

## 小结

Bin = 离散价格点，独立存储 X/Y。Active Bin 有两种代币可双向 Swap，被耗尽后 Active Bin 移动。LP 可自定义分布策略，费用在 Bin 级别独立计算。下一节展示 Sui DLMM 实现。
