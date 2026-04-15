# 5.7 随机数预言机：VRF 原理与各家实现

## 为什么链上需要随机数

```
链上随机数的难题：
  区块链是确定性系统 → 所有节点必须产出相同的结果
  因此无法使用传统的随机数生成器（如 /dev/urandom）

  如果你用 block_hash 做随机数：
    → 矿工/验证者可以选择性地忽略某些区块
    → 可以操纵"随机"结果

需要的场景：
  - NFT 盲盒：哪个 NFT 分配给谁？
  - 游戏：战斗结果、掉落概率
  - 抽奖：谁是赢家？
  - 公平排序：交易处理顺序
```

## VRF（可验证随机函数）原理

```
VRF 的核心思想：
  给定一个 seed（种子），生成一个随机数 + 一个证明
  任何人都可以验证这个随机数确实由这个 seed 生成
  但没有人能预测或操纵结果

数学直觉：
  1. 请求者提交 seed = hash(请求内容)
  2. VRF 使用私钥对 seed 进行计算
  3. 输出：random_value + proof
  4. 任何人可以用公钥验证 proof

安全保证：
  - 不可预测：在 seed 确定之前，无法预测结果
  - 不可偏倚：即使知道 seed，也无法选择结果
  - 可验证：任何人都可以独立验证结果正确
```

## Sui 内置随机数

Sui 提供了 `sui::random` 模块：

```move
module game::simple_random;

use sui::random::{Self, Random};

public fun roll_dice(rng: &mut Random): u8 {
    let mut buf = vector[0u8];
    random::generate_bytes(rng, &mut buf);
    *buf.borrow(0) % 6 + 1
}
```

**注意**：`sui::random` 由验证者生成，安全性取决于验证者诚实度。对于高价值场景，应使用专门的 VRF 预言机。

## Pyth Entropy（commit-reveal VRF）

```move
module game::pyth_entropy;

use sui::coin::Coin;
use sui::sui::SUI;

public struct Commitment has store {
    seed: vector<u8>,
    revealed: bool,
}

public fun commit(user_seed: vector<u8>): Commitment {
    Commitment { seed: user_seed, revealed: false }
}

public fun request_entropy(
    entropy: &mut Entropy,
    commitment: Commitment,
    reward: Coin<SUI>,
    ctx: &mut TxContext,
) {
    pyth_entropy::request(entropy, commitment.seed, reward, ctx);
}

public fun reveal(entropy: &mut Entropy, commitment: &mut Commitment): u64 {
    assert!(!commitment.revealed, 0);
    commitment.revealed = true;
    let random_bytes = pyth_entropy::reveal(entropy, commitment.seed);
    bytes_to_u64(random_bytes)
}

fun bytes_to_u64(bytes: vector<u8>): u64 {
    let mut result = 0u64;
    let mut i = 0;
    while (i < 8 && i < bytes.length()) {
        result = result + ((*bytes.borrow(i) as u64) << (i * 8));
        i = i + 1;
    };
    result
}
```

```
Pyth Entropy 流程（两步 commit-reveal）：

Step 1 - Commit：
  用户生成一个秘密 seed
  提交 seed 的 hash 到链上

Step 2 - Reveal：
  用户在下一笔交易中揭示 seed
  Pyth 使用 seed + 内部状态生成随机数
  由于用户在 commit 时不知道 Pyth 的内部状态
  → 无法操纵结果
```

## Supra VRF

```move
module game::supra_vrf;

use sui::coin::Coin;
use sui::sui::SUI;

public fun request_random(
    vrf: &mut SupraVrf,
    seed: vector<u8>,
    reward: Coin<SUI>,
    ctx: &mut TxContext,
): u64 {
    supra_vrf::request(vrf, seed, reward, ctx)
}

public fun verify_and_use(vrf: &SupraVrf, proof: &VrfProof): u64 {
    assert!(supra_vrf::verify(vrf, proof), 0);
    supra_vrf::get_randomness(proof)
}

public fun lottery_select_winner(
    vrf: &mut SupraVrf,
    ticket_count: u64,
    seed: vector<u8>,
    reward: Coin<SUI>,
    ctx: &mut TxContext,
): u64 {
    let randomness = request_random(vrf, seed, reward, ctx);
    randomness % ticket_count
}
```

## 三家 VRF 对比

| 维度     | Sui Random       | Pyth Entropy        | Supra VRF      |
| -------- | ---------------- | ------------------- | -------------- |
| 安全模型 | 验证者生成       | commit-reveal       | DORA 共识      |
| 可验证性 | 无链上证明       | 有证明              | 有证明         |
| 延迟     | 即时（同交易）   | 2 笔交易            | 1-2 笔交易     |
| Gas 成本 | 最低             | 中等                | 中等           |
| 操纵难度 | 中（依赖验证者） | 高（commit-reveal） | 高（共识保护） |
| 适用场景 | 低价值、快速     | 高价值、公平性要求  | 高价值、低延迟 |

## 随机数使用的最佳实践

```move
module game::random_best_practice;

use sui::random::Random;

public struct Lottery has key {
    id: UID,
    ticket_count: u64,
    committed_seed: Option<vector<u8>>,
    winner: Option<u64>,
    phase: u8,
}

const PHASE_OPEN: u8 = 0;
const PHASE_COMMITTED: u8 = 1;
const PHASE_REVEALED: u8 = 2;

public fun draw(lottery: &mut Lottery, rng: &mut Random) {
    assert!(lottery.phase == PHASE_COMMITTED, 0);
    let mut buf = vector[0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8];
    random::generate_bytes(rng, &mut buf);
    let mut val = 0u64;
    let mut i = 0;
    while (i < 8) {
        val = val + ((*buf.borrow(i) as u64) << (i * 8));
        i = i + 1;
    };
    lottery.winner = option::some(val % lottery.ticket_count);
    lottery.phase = PHASE_REVEALED;
}
```

## 风险分析

| 风险               | 描述                                             |
| ------------------ | ------------------------------------------------ |
| 验证者操纵         | Sui 内置随机数依赖验证者诚实度                   |
| commit-reveal 延迟 | Pyth Entropy 需要两笔交易，有时间窗口            |
| seed 可预测        | 如果 seed 选择不当（如用时间戳），结果可能被预测 |
| 拒绝服务           | 如果随机数生成失败，游戏可能卡住                 |
