/** Sui Testnet Pyth / Wormhole 状态对象（见 Pyth 官方文档，升级时会变） */
export const PYTH_STATE_TESTNET =
  "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c";
export const WORMHOLE_STATE_TESTNET =
  "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790";

/** SUI/USD feed id（hex 带 0x，Hermes 与链上一致） */
export const SUI_USD_FEED_ID =
  "0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";

export const CLOCK_ID =
  "0x0000000000000000000000000000000000000000000000000000000000000006";

export const HERMES_BETA = "https://hermes-beta.pyth.network";

/** 合约要求：20 SUI = 20 * 10^9 MIST */
export const SEED_TOTAL_MIST = 20n * 1_000_000_000n;
