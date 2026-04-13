import { useCallback, useMemo, useState } from "react";
import {
  ConnectButton,
  useCurrentAccount,
  useSignAndExecuteTransaction,
  useSuiClient,
} from "@mysten/dapp-kit";
import { formatAddress } from "@mysten/sui/utils";
import { Transaction } from "@mysten/sui/transactions";
import { SuiPythClient } from "@pythnetwork/pyth-sui-js";
import { SuiPriceServiceConnection } from "@pythnetwork/pyth-sui-js";
import {
  CLOCK_ID,
  HERMES_BETA,
  PYTH_STATE_TESTNET,
  SEED_TOTAL_MIST,
  SUI_USD_FEED_ID,
  WORMHOLE_STATE_TESTNET,
} from "./constants";

const DEFAULT_PKG =
  import.meta.env.VITE_PACKAGE_ID ??
  "0x0000000000000000000000000000000000000000000000000000000000000000";

export default function App() {
  const currentAccount = useCurrentAccount();
  const suiClient = useSuiClient();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();

  const [packageId, setPackageId] = useState(DEFAULT_PKG);
  const [roundId, setRoundId] = useState("");
  const [flatBps, setFlatBps] = useState("5");
  const [betMist, setBetMist] = useState("1000000000");
  const [log, setLog] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const pythClient = useMemo(
    () => new SuiPythClient(suiClient, PYTH_STATE_TESTNET, WORMHOLE_STATE_TESTNET),
    [suiClient],
  );

  const priceConnection = useMemo(
    () => new SuiPriceServiceConnection(HERMES_BETA),
    [],
  );

  const pushLog = useCallback((msg: string) => {
    setLog(msg);
    setErr(null);
  }, []);

  const pushErr = useCallback((e: unknown) => {
    setErr(e instanceof Error ? e.message : String(e));
    setLog(null);
  }, []);

  const createRound = async () => {
    if (!currentAccount) {
      pushErr(new Error("请先连接钱包"));
      return;
    }
    if (!packageId || packageId.length < 10) {
      pushErr(new Error("填写已发布的 package ID"));
      return;
    }
    try {
      const updates = await priceConnection.getPriceFeedsUpdateData([
        SUI_USD_FEED_ID,
      ]);
      const tx = new Transaction();
      const priceInfoIds = await pythClient.updatePriceFeeds(tx, updates, [
        SUI_USD_FEED_ID,
      ]);
      const priceObj = priceInfoIds[0];
      if (!priceObj) throw new Error("未拿到 PriceInfo 对象 ID");

      const [seed] = tx.splitCoins(tx.gas, [SEED_TOTAL_MIST]);
      tx.moveCall({
        target: `${packageId}::market::create_round_default`,
        arguments: [
          seed,
          tx.object(CLOCK_ID),
          tx.object(priceObj),
          tx.pure.u64(BigInt(flatBps || "5")),
        ],
      });

      const res = await signAndExecute({ transaction: tx });
      pushLog(`创建回合 digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  const betUp = async () => {
    if (!roundId) {
      pushErr(new Error("填写 Round 共享对象 ID"));
      return;
    }
    try {
      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [BigInt(betMist)]);
      tx.moveCall({
        target: `${packageId}::market::bet_up`,
        arguments: [tx.object(roundId), coin, tx.object(CLOCK_ID)],
      });
      const res = await signAndExecute({ transaction: tx });
      pushLog(`bet_up digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  const betDown = async () => {
    if (!roundId) {
      pushErr(new Error("填写 Round 共享对象 ID"));
      return;
    }
    try {
      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [BigInt(betMist)]);
      tx.moveCall({
        target: `${packageId}::market::bet_down`,
        arguments: [tx.object(roundId), coin, tx.object(CLOCK_ID)],
      });
      const res = await signAndExecute({ transaction: tx });
      pushLog(`bet_down digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  const settle = async () => {
    if (!roundId) {
      pushErr(new Error("填写 Round ID"));
      return;
    }
    try {
      const updates = await priceConnection.getPriceFeedsUpdateData([
        SUI_USD_FEED_ID,
      ]);
      const tx = new Transaction();
      const priceInfoIds = await pythClient.updatePriceFeeds(tx, updates, [
        SUI_USD_FEED_ID,
      ]);
      const priceObj = priceInfoIds[0];
      if (!priceObj) throw new Error("price object missing");
      tx.moveCall({
        target: `${packageId}::market::settle`,
        arguments: [tx.object(roundId), tx.object(CLOCK_ID), tx.object(priceObj)],
      });
      const res = await signAndExecute({ transaction: tx });
      pushLog(`settle digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  const claimWinner = async () => {
    if (!roundId) return;
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${packageId}::market::claim_winner`,
        arguments: [tx.object(roundId)],
      });
      const res = await signAndExecute({ transaction: tx });
      pushLog(`claim_winner digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  const claimVoid = async () => {
    if (!roundId) return;
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${packageId}::market::claim_void_refund`,
        arguments: [tx.object(roundId)],
      });
      const res = await signAndExecute({ transaction: tx });
      pushLog(`claim_void_refund digest: ${res.digest}`);
    } catch (e) {
      pushErr(e);
    }
  };

  return (
    <>
      <h1>SUI / USD 10 分钟涨跌（Pyth · Testnet）</h1>
      <p style={{ fontSize: "0.9rem", color: "#888" }}>
        创建回合需支付 20 SUI 种子（合约拆成涨跌各 10 SUI）。请先{" "}
        <code>sui client publish</code> 部署并把 Package ID 写入环境变量{" "}
        <code>VITE_PACKAGE_ID</code> 或下方输入框。
      </p>

      <section>
        <ConnectButton />
        {currentAccount && (
          <p style={{ fontSize: "0.85rem" }}>
            当前账户：{formatAddress(currentAccount.address)}
          </p>
        )}
      </section>

      <section>
        <label>Package ID</label>
        <input
          value={packageId}
          onChange={(e) => setPackageId(e.target.value.trim())}
        />
        <label>Round 对象 ID（创建成功后从浏览器或 sui explorer 复制）</label>
        <input value={roundId} onChange={(e) => setRoundId(e.target.value.trim())} />
        <label>平盘阈值 flat_bps（默认 5 = 0.05%）</label>
        <input value={flatBps} onChange={(e) => setFlatBps(e.target.value)} />
        <label>单次押注金额（MIST，1 SUI = 1e9）</label>
        <input value={betMist} onChange={(e) => setBetMist(e.target.value)} />
      </section>

      <section>
        <h2>操作</h2>
        <button type="button" onClick={createRound}>
          1. 更新 Pyth 并创建回合（付 20 SUI）
        </button>
        <button type="button" onClick={betUp}>
          押涨 bet_up
        </button>
        <button type="button" onClick={betDown}>
          押跌 bet_down
        </button>
        <button type="button" onClick={settle}>
          结算 settle（需过截止时间 + 更新 Pyth）
        </button>
        <button type="button" onClick={claimWinner}>
          胜方领取 claim_winner
        </button>
        <button type="button" onClick={claimVoid}>
          平盘退款 claim_void_refund
        </button>
      </section>

      {log && <p className="ok">{log}</p>}
      {err && <p className="err">{err}</p>}
    </>
  );
}
