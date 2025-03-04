import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [liquidate, calls] = await deployer.deferContract(
  "Liquidate",
  CallData.compile({ core: deployer.config.protocol.ekubo.core!, singleton: deployer.config.protocol.singleton! }),
);

let response = await deployer.execute([...calls]);
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { liquidate: liquidate.address });
