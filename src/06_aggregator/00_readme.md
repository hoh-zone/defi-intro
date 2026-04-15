# 第 6 章 DEX 聚合器：最优路径与拆单执行（以 Cetus 聚合器架构为主线）

## 本章在教什么

当 Sui 上同时存在 **CLMM、DLMM、订单簿、CPMM** 等多种流动性形态时，同一笔 `A → B` 的最优成交往往来自 **多跳、多池、甚至多协议** 的组合。聚合器负责两件事：

1. **链下**：在可用报价源上搜索路径、估算输出、给出可签名的 **路由计划**（含每跳池子、方向、数量级）。
2. **链上**：在 **单笔交易（PTB）** 内按顺序调用各 DEX 模块，并用 **统一上下文对象** 约束最小输出、手续费与退款逻辑，保证 **原子性**。

本章**不再用虚构的 `aggregator::RoutePlan` 伪代码当主菜**，而是以 **Cetus 团队开源的聚合器 SDK / 路由适配代码** 为参照（仓库通常名为 `aggregator`，核心在 `src/movecall/`、`src/movecall/router.ts`、`src/api.ts` 等）。你本地若已克隆，可直接打开对照阅读。

> **说明（避免混淆「V2」）**  
> 开源仓库里同时存在 **聚合器 Move 包的演进（如 `aggregator_v2` / v3 等命名）** 与 **链上入口 `router::new_swap_context_v2`**。后者表示 **SwapContext 的第二种构造方式**（增加 `max_amount_in` 等校验），与「整个产品叫 V2」不是同一概念。文中会分开写清。

## 阅读前提

- 已读 **第 4 章**（AMM / CLMM 直觉）与 **第 5 章**（价格与操纵面）。
- 具备 **Sui PTB** 与 **TypeScript SDK** 的基本概念即可；不要求逐行读完整个 `aggregator` 仓库。

## 本章结构（10 节）

| 小节 | 文件                                                                     | 内容                                                                              |
| ---- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| 6.1  | [01_problem_and_scope.md](./01_problem_and_scope.md)                     | 问题定义、与单 DEX 对比、本章边界                                                 |
| 6.2  | [02_three_layers.md](./02_three_layers.md)                               | 链下报价 · 链上路由合约 · 各 DEX 结算                                             |
| 6.3  | [03_onchain_router_swap_context.md](./03_onchain_router_swap_context.md) | `SwapContext`、`router::new_swap_context` / `new_swap_context_v2`、`confirm_swap` |
| 6.4  | [04_dex_router_and_path_model.md](./04_dex_router_and_path_model.md)     | `DexRouter` 接口、`Path` / `FlattenedPath`、provider 与 `published_at`            |
| 6.5  | [05_cetus_clmm_integration.md](./05_cetus_clmm_integration.md)           | Cetus CLMM 一跳：`CetusRouter` 与 `cetus::swap` 参数编排                          |
| 6.6  | [06_dlmm_and_package_versioning.md](./06_dlmm_and_package_versioning.md) | DLMM 腿、多模块 `published_at`、与扩展包                                          |
| 6.7  | [07_deepbook_v3_integration.md](./07_deepbook_v3_integration.md)         | DeepBook V3 腿与 `extended_details`（如参考池喂价）                               |
| 6.8  | [08_quote_api_ptb.md](./08_quote_api_ptb.md)                             | 链下 API、`packages` 映射、组装完整交易                                           |
| 6.9  | [09_split_gas_slippage.md](./09_split_gas_slippage.md)                   | 拆单直觉、滑点、`MAX_AMOUNT_IN`、Gas 意识                                         |
| 6.10 | [10_cases_security.md](./10_cases_security.md)                           | 生产部署、升级、风控与免责                                                        |

## 参考代码位置

### 本书内：可编译的 Move 教学包

为弥补「主网路由 Move 往往不全量开源」带来的空洞，仓库内提供 **最小可编译** 示例，演示 **`SwapContext` 字段、`new_swap_context_v2` 断言、`record_leg_output`、`confirm_swap`**：

- `src/06_aggregator/code/aggregator_router_tutorial/sources/router_tutorial.move`
- 构建：`cd src/06_aggregator/code/aggregator_router_tutorial && sui move build`

它与 Cetus 主网合约 **不等价**，只用于 **对齐概念与断点调试**。

### 外部：Cetus 聚合器开源（推荐本地克隆）

若你在本机克隆了 Cetus 聚合器（例如目录名 `aggregator/`），建议优先阅读：

- `src/movecall/router.ts` — `new_swap_context` / `confirm_swap` 的 PTB 封装
- `src/movecall/index.ts` — `DexRouter` 接口
- `src/movecall/cetus.ts` — Cetus CLMM 包装层 `::cetus::swap`
- `src/movecall/deepbook_v3.ts` — DeepBook V3 与 `extended_details`
- `src/api.ts` — `parseRouterResponse` 与 `packages`

本书正文**不复制**该仓库全文；文中 **TypeScript 引用块** 路径以克隆目录为根（如 `src/movecall/router.ts`）。接口与地址以**当时链上部署**为准。
