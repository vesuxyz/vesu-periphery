import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [multiply, calls] = await deployer.deferContract(
  "Multiply",
  CallData.compile({ core: deployer.config.protocol.ekubo.core!, singleton: deployer.config.protocol.singleton! }),
);

let response = await deployer.execute([...calls]);
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { multiply: multiply.address });
