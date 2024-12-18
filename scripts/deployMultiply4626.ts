import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [multiply4626, calls] = await deployer.deferContract(
  "Multiply4626",
  CallData.compile({ core: deployer.config.protocol.ekubo!, singleton: deployer.config.protocol.singleton! }),
);

let response = await deployer.execute([...calls]);
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { multiply4626: multiply4626.address });
