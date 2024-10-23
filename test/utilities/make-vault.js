const Vault = artifacts.require("VaultV2");
const GMXVault = artifacts.require("VaultV2GMX");
const VaultProxy = artifacts.require("VaultProxy");

module.exports = async function(implementationAddress, useGMX, ...args) {
  const fromParameter = args[args.length - 1]; // corresponds to {from: governance}
  const vaultAsProxy = await VaultProxy.new(implementationAddress, fromParameter);
  let vault
  if (useGMX) {
    vault = await GMXVault.at(vaultAsProxy.address);
  } else {
    vault = await Vault.at(vaultAsProxy.address)
  }
  await vault.initializeVault(...args);
  return vault;
};
