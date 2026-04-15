# 第 6 章配套代码

## `aggregator_router_tutorial/`（推荐）

- **内容**：单模块 `router_tutorial`，实现 **教学用** `SwapContext`、`new_swap_context`、`new_swap_context_v2`（`max_in` 断言）、`record_leg_output`、`confirm_swap`。
- **目的**：与书中 **6.3 节** 对照，理解链上上下文 **长什么样**；**不等于** Cetus 主网路由合约。
- **构建**：`cd aggregator_router_tutorial && sui move build`

## `aggregator_ts/`（遗留）

- 早期多跳拆分示例，**SDK 版本可能较旧**，仅保留思路参考。

## 生产级参考

完整路由、全 DEX 适配与 API 见 **Cetus 开源聚合器仓库**（自行克隆到本机后阅读 `src/movecall/`、`src/api.ts`）。
