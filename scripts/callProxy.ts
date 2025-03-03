import { CallData, hash, shortString } from "starknet";
import { setup, toI257, SCALE } from "../lib";

const deployer = await setup(process.env.NETWORK);
const proxy = await deployer.loadContract("0x014ff73663ff86c1629dcfe38a5af233b4c74b27d31fdc5c9db1d23a7fbfb48c");
await proxy.connect(deployer.creator);

console.log("Proxy:", proxy.address);
const manager = await proxy.manager();
console.log("Proxy Manager:", manager);

const protocol = await deployer.loadProtocol();
const { singleton, assets, extensionPO } = protocol;
await extensionPO.connect(deployer.creator);

const poolName = "genesis-pool";
const pool = await protocol.loadPool(poolName);

const response = await proxy.proxy_call([{
  to: extensionPO.address,
  selector: hash.getSelectorFromName('set_shutdown_ltv_config'),
  calldata: CallData.compile({
    pool_id: pool.id,
    collateral_asset: assets[0].address,
    debt_asset: assets[1].address,
    ltv_config: { max_ltv: SCALE }
  })
}]);

console.log(await deployer.waitForTransaction(response.transaction_hash));
