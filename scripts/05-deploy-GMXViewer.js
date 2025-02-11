const prompt = require('prompt');
const hre = require("hardhat");
const { type2Transaction } = require('./utils.js');

async function main() {
  const ImplContract = artifacts.require("GMXViewer");
  const impl = await type2Transaction(ImplContract.new, "0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8", "0xa11B501c2dd83Acd29F6727570f2502FAaa617F2", "0x23D4Da5C7C6902D4C86d551CaE60d5755820df9E");

  console.log("Deployment complete. Implementation deployed at:", impl.creates);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
