import React from "react";
import ReactDOM from "react-dom/client";
import { Buffer } from "buffer";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createNetworkConfig,
  SuiClientProvider,
  WalletProvider,
} from "@mysten/dapp-kit";
import { getJsonRpcFullnodeUrl } from "@mysten/sui/jsonRpc";
import "@mysten/dapp-kit/dist/index.css";

import App from "./App";
import "./index.css";

(globalThis as unknown as { Buffer: typeof Buffer }).Buffer = Buffer;

const queryClient = new QueryClient();

const { networkConfig } = createNetworkConfig({
  testnet: {
    url: getJsonRpcFullnodeUrl("testnet"),
    network: "testnet",
  },
});

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <SuiClientProvider networks={networkConfig} defaultNetwork="testnet">
        <WalletProvider autoConnect>
          <App />
        </WalletProvider>
      </SuiClientProvider>
    </QueryClientProvider>
  </React.StrictMode>,
);
