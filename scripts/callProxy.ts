import { CallData, hash } from "starknet";
import { setup, SCALE } from "../lib";

const deployer = await setup(process.env.NETWORK);
const proxy = await deployer.loadContract(process.env.PROXY_ADDRESS!);
await proxy.connect(deployer.creator);

console.log("Proxy:", proxy.address);
const manager = await proxy.manager();
console.log("Proxy Manager:", manager);

const protocol = await deployer.loadProtocol();
const { singleton, assets, extensionPO } = protocol;
await extensionPO.connect(deployer.creator);

const poolName = "genesis-pool";
const pool = await protocol.loadPool(poolName);

// const response = await proxy.proxy_call([{
//   to: extensionPO.address,
//   selector: hash.getSelectorFromName('set_pool_owner'),
//   calldata: CallData.compile({
//     pool_id: pool.id,
//     owner: "0x30999f6fe247d7227ad3b5fefefc37754bdf0904b5c09a487b3202f13aeb92e"
//   })
// }]);

// console.log(await deployer.waitForTransaction(response.transaction_hash));

// const response = await proxy.proxy_call([{
//   to: extensionPO.address,
//   selector: hash.getSelectorFromName('set_shutdown_ltv_config'),
//   calldata: CallData.compile({
//     pool_id: pool.id,
//     collateral_asset: assets[0].address,
//     debt_asset: assets[1].address,
//     ltv_config: { max_ltv: SCALE }
//   })
// }]);

// console.log(await deployer.waitForTransaction(response.transaction_hash));
