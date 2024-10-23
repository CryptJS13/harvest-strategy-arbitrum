const addresses = require("../test/test-config.js");
const { type2Transaction } = require('./utils.js');

async function main() {
  const StrategyImpl = artifacts.require("GMXStrategyMainnet_WBTC");
  const StrategyProxy = artifacts.require("StrategyProxy");
  const VaultImpl = artifacts.require("VaultV2GMX");
  const VaultProxy = artifacts.require("VaultProxy");
  
  const strImpl = await type2Transaction(StrategyImpl.new);
  console.log("Strategy implementation deployed at:", strImpl.creates);
  const vltImpl = await type2Transaction(VaultImpl.new);
  console.log("Vault implementation deployed at:   ", vltImpl.creates);
  const vltCont = await VaultImpl.at(vltImpl.creates);
  await vltCont.initializeVault(
    addresses.Storage,
    addresses.iFARM,
    10000,
    10000,
  );
  console.log("Vault implementation initialized");

  const vltProxy = await type2Transaction(VaultProxy.new, vltImpl.creates);
  console.log("Vault proxy deployed at:            ", vltProxy.creates);
  const vault = await VaultImpl.at(vltProxy.creates);
  await vault.initializeVault(
    addresses.Storage,
    "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f",
    10000,
    10000,
  )
  console.log("Vault proxy initialized");

  const strProxy = await type2Transaction(StrategyProxy.new, strImpl.creates);
  console.log("Strategy proxy deployed at:         ", strProxy.creates);
  const strat = await StrategyImpl.at(strProxy.creates);
  await strat.initializeStrategy(
    addresses.Storage,
    vltProxy.creates,
  )
  console.log("Strategt proxy initialized");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
