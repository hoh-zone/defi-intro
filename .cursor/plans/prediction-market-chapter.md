# 第 17 章 Prediction Market（30 节）— 修订版计划

## 章节位置与全书编号调整

- **插入点**：在**原「第 17 章 DeFi 攻击模式与经典案例」之前**新增一整章。
- **新编号**：
  - **第 17 章** — 预测市场（Prediction Market）设计与实现 · Sui 版（30 节：`17.1`–`17.30`）
  - **第 18 章** — 原第 17 章（攻击模式）
  - **第 19 章** — 原第 18 章（协议工程化）
  - **第 20 章** — 原第 19 章（审计准备）
  - **第 21 章** — 原第 20 章（Move 安全实践）
  - **第 22 章** — 原第 21 章（风险控制全景）

## 篇（Part）结构（推荐）

- **第四篇「收益与杠杆」**：第 10–**17** 章（在原 10–16 基础上 **增加第 17 章预测市场**；本篇由七章变为**八章**）。
- **第五篇「警惕」**：第 **18–22** 章（对应原 17–21 章内容顺延，篇内递进关系不变：攻击 → 工程 → 审计 → Move 安全 → 系统风险）。

若希望「第五篇」仍以攻击开篇，可改为备选：**第 17 章放在第五篇首章、第 16 章后不接长章**——不推荐，会打断「机制篇 / 警惕篇」分界；**默认采用上段结构**。

## 仓库目录与文件重命名（执行阶段一次性完成）

为与全书 `NN_topic` 约定一致，建议**重命名目录**并更新所有链接：

| 原路径 | 新路径 |
|--------|--------|
| （新建） | `src/17_prediction_market/` |
| `src/17_attacks/` | `src/18_attacks/` |
| `src/18_engineering/` | `src/19_engineering/` |
| `src/19_audit/` | `src/20_audit/` |
| `src/20_security/` | `src/21_security/` |
| `src/21_risk_control/` | `src/22_risk_control/` |

- **小节编号**：原 `17_attacks/01_*.md` 文内标题由「17.1」改为「**18.1**」；`18_engineering` → **19.x**；依此类推到 **22.x**（`21_risk_control` → **22.x**）。
- **SUMMARY.md**：插入第 17 章树状目录；其后各章标题与路径改为 `18_attacks` … `22_risk_control`；子节锚点同步 +1。
- **篇导读**：[`src/part4_yield.md`](src/part4_yield.md) 增加第 17 章条目；[`src/part5_security.md`](src/part5_security.md) 中「第 17 章」起全部改为 **18–22** 章表述与递进说明。
- **全书交叉引用**：对 `src/` 内搜索「第 17 章」「17_attacks」「原 17」等，按语境改为新编号或指向预测市场/攻击章的正确章节号。
- **README / 附录 E**：[`README.md`](README.md) 若含章节目录表，同步更新；[`src/appendix/05_code_index.md`](src/appendix/05_code_index.md) 中攻击、工程、审计、安全、风控条目章节号 +1，并新增预测市场代码索引行。
- **16.7 短节**：[`src/16_bridge_insurance/07_prediction_market.md`](src/16_bridge_insurance/07_prediction_market.md) 指向**第 17 章**详解（非旧「第 22 章」）。

## 第 17 章内容结构（30 节，与先前大纲一致，仅节号前缀改为 17）

- Part 0：`17.1`–`17.4` — 基础、价值、角色、模块图  
- Part 1：`17.5`–`17.7` — 二元市场、生命周期、`Market` 对象  
- Part 2：`17.8`–`17.11` — 条件代币、抵押恒等、`Position`、Split/Merge  
- Part 3：`17.12`–`17.14` — Mint/Burn 经济解释、流动性、Outcome Token 模块  
- Part 4：`17.15`–`17.19` — AMM 必要性、LMSR 公式与直觉、b 参数、LMSR Engine  
- Part 5：`17.20`–`17.22` — 买卖流程、交易函数  
- Part 6：`17.23`–`17.26` — Polymarket 对照、池结构、Market Pool、Oracle 争议窗口  
- Part 7：`17.27`–`17.28` — Resolution、Claim  
- Part 8：`17.29`–`17.30` — 多结果、Scalar  

## Move 代码包路径

- 建议：[`src/17_prediction_market/code/prediction_market/`](src/17_prediction_market/code/prediction_market/)（与章节号一致）。

## 叙事约束（不变）

- Polymarket：CTF + 链下撮合与链上结算分工，**不等于**纯 LMSR；对照表保留。  
- Augur：争议与 REP 作对比，不全量实现。

## 实施顺序（执行阶段）

1. **重命名目录** `17_attacks`→`18_attacks` … `21_risk_control`→`22_risk_control`（或 git mv 分批）。  
2. **批量更新**各目录内 `00_readme.md` 与小节标题编号（17→18 … 21→22）。  
3. **新建** `17_prediction_market/` 全文与代码包。  
4. **更新** `SUMMARY.md`、`part4_yield.md`、`part5_security.md`、附录与跨章引用。  
5. **mdbook build** 与全文链接检查。

## Todos（与修订结构对齐）

- `renumber-dirs`：目录 `17_attacks`…`21_risk_control` → `18_`…`22_`，并更新文内章节号。  
- `scaffold-ch17`：新建 `src/17_prediction_market/`（`00_readme` + 30 节）。  
- `move-package`：在 `17_prediction_market/code/` 实现 CTF + LMSR + 结算 + 扩展。  
- `book-links`：`SUMMARY`、两篇导读、`16.7`、`appendix/05`、`README` 与全书交叉引用。
