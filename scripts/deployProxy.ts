import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [proxy, calls] = await deployer.deferContract(
  "Proxy",
  CallData.compile({ manager: deployer.address }),
);

let response = await deployer.execute([...calls], undefined, { maxFee: 2362057423272n });
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { proxy: proxy.address });
