import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [rebalance, calls] = await deployer.deferContract(
  "Rebalance",
  CallData.compile({
    core: deployer.config.protocol.ekubo.core!, singleton: deployer.config.protocol.singleton!, owner: deployer.address, fee_rate: 0
  }),
);

let response = await deployer.execute([...calls]);
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { rebalance: rebalance.address });
