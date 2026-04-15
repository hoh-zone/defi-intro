# 6.10 实例、升级与安全清单

## 读开源仓库时的建议顺序

1. **本书** `code/aggregator_router_tutorial/sources/router_tutorial.move` — 先建立 **SwapContext / confirm** 的直觉（可编译）；
2. `src/movecall/router.ts`（Cetus 聚合器仓库）— **真实** `new_swap_context` / `confirm_swap` 参数；
3. `src/movecall/index.ts` — **`DexRouter`**；
4. `src/movecall/cetus.ts` — **CLMM 一跳** `::cetus::swap`；
5. `src/movecall/deepbook_v3.ts` — **订单簿一跳** 与 `extended_details`；
6. `src/api.ts` — **`parseRouterResponse` 与 `packages`**；
7. `tests/aggregatorv3/router/*.test.ts` — **集成测试**（若有）辅助理解参数。

## 生产集成检查清单（简版）

| 项目     | 说明                                                        |
| -------- | ----------------------------------------------------------- |
| 包地址   | `packages` 与链上注册是否一致；升级后是否同步               |
| 池对象   | 池 ID 与 `published_at` 是否匹配                            |
| 限额     | `amount_out_limit` / `max_amount_in` 是否与产品风险策略一致 |
| 失败文案 | 解析 Move `abort` 与 RPC 错误，给用户可行动提示             |
| 监控     | 成功率、滑点偏离、Gas、报价延迟                             |

## 免责声明

链上地址、模块名与测试用例会随时间变化；**请勿把本书中的举例当作当前主网唯一真相**。集成、上线与资金安全相关决策，应以 **官方文档、审计报告与自有测试** 为准。
