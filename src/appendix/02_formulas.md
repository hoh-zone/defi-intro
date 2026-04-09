# 附录 B 核心公式与计算示例

## AMM

### 恒定乘积

$$x \cdot y = k$$

### Swap 输出计算

$$\Delta y = \frac{\Delta x \cdot y}{x + \Delta x}$$

含手续费：

$$\Delta y = \frac{\Delta x \cdot (1 - f) \cdot y}{x + \Delta x \cdot (1 - f)}$$

其中 $f$ 是手续费率。

### 滑点

$$\text{Slippage} = \frac{P_{actual} - P_{expected}}{P_{expected}}$$

### 无常损失

$$IL = 2 \cdot \frac{\sqrt{P_{after}/P_{before}}}{1 + P_{after}/P_{before}} - 1$$

### LP 份额计算

$$\text{shares} = \frac{\text{deposit} \cdot \text{total\_shares}}{\text{total\_principal}}$$

## 利率模型

### 利用率

$$U = \frac{\text{Total Borrows}}{\text{Total Deposits}}$$

### 拐点利率模型

$$r_{borrow} = \begin{cases} r_0 + \frac{U}{U_{opt}} \cdot s_1 & U \leq U_{opt} \\ r_0 + s_1 + \frac{U - U_{opt}}{1 - U_{opt}} \cdot s_2 & U > U_{opt} \end{cases}$$

### 存款利率

$$r_{supply} = r_{borrow} \cdot U \cdot (1 - f_{reserve})$$

### 示例

参数：$r_0 = 2\%$, $s_1 = 4\%$, $s_2 = 75\%$, $U_{opt} = 80\%$, $f_{reserve} = 10\%$

$U = 60\%$ 时：
- $r_{borrow} = 2\% + 60\%/80\% \times 4\% = 2\% + 3\% = 5\%$
- $r_{supply} = 5\% \times 60\% \times 90\% = 2.7\%$

$U = 90\%$ 时：
- $r_{borrow} = 2\% + 4\% + (90\%-80\%)/(100\%-80\%) \times 75\% = 6\% + 37.5\% = 43.5\%$
- $r_{supply} = 43.5\% \times 90\% \times 90\% = 35.2\%$

## 借贷

### 健康因子

$$HF = \frac{\sum (\text{Collateral}_i \cdot P_i \cdot LT_i)}{\sum (\text{Debt}_j \cdot P_j)}$$

其中 $P$ 是价格，$LT$ 是清算阈值。

### 示例

用户存入 1000 SUI（$2/SUI），借出 1000 USDC。清算阈值 80%。

- 抵押品价值 = 1000 × 2 = $2000
- 调整后抵押品 = $2000 × 80% = $1600
- 债务价值 = $1000
- HF = $1600 / $1000 = 1.6（安全）

SUI 跌到 $1.3：
- 调整后抵押品 = 1000 × 1.3 × 80% = $1040
- HF = $1040 / $1000 = 1.04（危险）

## CDP

### 抵押率

$$CR = \frac{\text{Collateral Value}}{\text{Debt Value}}$$

### 清算条件

$$CR < \text{Liquidation Threshold}$$

### 清算罚金

$$\text{Seized} = \text{Debt Value} \times (1 + \text{Penalty Rate})$$

## 衍生品

### PnL

$$\text{Long PnL} = (\text{Exit Price} - \text{Entry Price}) \times \text{Size}$$

$$\text{Short PnL} = (\text{Entry Price} - \text{Exit Price}) \times \text{Size}$$

### 强平价格

$$\text{Long Liq Price} = \text{Entry Price} \times (1 - \frac{1}{\text{Leverage}} + \text{MM Rate})$$

$$\text{Short Liq Price} = \text{Entry Price} \times (1 + \frac{1}{\text{Leverage}} - \text{MM Rate})$$

### 资金费率

$$\text{Funding} = \text{Position Size} \times \text{Funding Rate}$$

## APY

### 复利 APY

$$APY = (1 + \frac{r}{n})^n - 1$$

其中 $r$ 是单期利率，$n$ 是每年的复利次数。

### 示例

APR = 100%，每区块复利（以太坊约每年 2,102,400 个区块）：

$$APY = (1 + \frac{1}{2102400})^{2102400} - 1 \approx 171.9\%$$

## 归属（Vesting）

### 线性归属

$$\text{Vested}(t) = \text{Total} \times \frac{t - t_{start}}{t_{end} - t_{start}}$$

### 悬崖 + 线性归属

$$\text{Vested}(t) = \begin{cases} 0 & t < t_{cliff} \\ \text{Total} \times \frac{t - t_{start}}{t_{end} - t_{start}} & t \geq t_{cliff} \end{cases}$$
