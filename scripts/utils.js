async function getSigner() {
  const signer = await ethers.provider.getSigner();
  return signer;
}

async function type2Transaction(callFunction, ...params) {
  const signer = await getSigner();
  const unsignedTx = await callFunction.request(...params);
  const tx = await signer.sendTransaction({
    from: unsignedTx.from,
    to: unsignedTx.to,
    data: unsignedTx.data,
    gasPrice: 1e8,
    gasLimit: 300e6
  });
  await tx.wait();
  return tx;
}

module.exports = {
  type2Transaction,
};
