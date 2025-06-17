import { CairoCustomEnum, CallData, hash } from "starknet";
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

const poolOwner = await extensionPO.pool_owner(pool.id);
console.log("Pool Owner:", poolOwner);

const hnAccount = "0x773daa9f2605288be0e7586fa8390b7a9f9c4016dc36f68c7effa48de125583";

// set local account as proxy owner
// const response = await proxy.set_manager(deployer.creator.address);
// await deployer.waitForTransaction(response.transaction_hash);

console.log("Pool:", pool.id);

const response = await extensionPO.populateTransaction.set_shutdown_mode(
  pool.id,
  new CairoCustomEnum({ None: {}, Recovery: undefined, Subscription: undefined, Redemption: undefined })
);
console.log(response);

// allow hn account to call set_shutdown_ltv_config on proxy
// const response = await proxy.set_caller_for_method(
//   hnAccount,
//   extensionPO.address,
//   hash.getSelectorFromName('set_shutdown_ltv_config'),
//   true
// );
// await deployer.waitForTransaction(response.transaction_hash);
// console.log(await proxy.access_control(hnAccount, extensionPO.address, hash.getSelectorFromName('set_shutdown_ltv_config')));

// set proxy as pool owner
// const response = await extensionPO.set_pool_owner(pool.id, proxy.address);
// await deployer.waitForTransaction(response.transaction_hash);



// call set_shutdown_ltv_config on pool via proxy via hn account
// const response = await proxy.populateTransaction.proxy_call([{
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
// await deployer.waitForTransaction(response.transaction_hash);



// const response = await proxy.proxy_call([{
//   to: extensionPO.address,
//   selector: hash.getSelectorFromName('set_pool_owner'),
//   calldata: CallData.compile({
//     pool_id: pool.id,
//     owner: "0x30999f6fe247d7227ad3b5fefefc37754bdf0904b5c09a487b3202f13aeb92e"
//   })
// }]);
// console.log(await deployer.waitForTransaction(response.transaction_hash));

// const calldata = await proxy.populateTransaction.proxy_call([{
//   to: extensionPO.address,
//   selector: hash.getSelectorFromName('set_shutdown_ltv_config'),
//   calldata: CallData.compile({
//     pool_id: pool.id,
//     collateral_asset: assets[0].address,
//     debt_asset: assets[1].address,
//     ltv_config: { max_ltv: SCALE }
//   })
// }]);
// console.log(calldata);

// const response = await proxy.populateTransaction.proxy_call([{
//   to: proxy.address,
//   selector: hash.getSelectorFromName('access_control'),
//   calldata: CallData.compile({
//     caller: deployer.address,
//     contract: extensionPO.address,
//     method: hash.getSelectorFromName('set_shutdown_ltv_config')
//   })
// }]);
// console.log(response);
// console.log(await deployer.waitForTransaction(response.transaction_hash));
