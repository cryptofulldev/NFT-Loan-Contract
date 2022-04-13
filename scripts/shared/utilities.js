const { ethers } = require("hardhat");
const { BigNumber } = ethers;

// Defaults to e18 using amount * 10^18
function getBigNumber(amount, decimals = 18) {
  return BigNumber.from(amount).mul(BigNumber.from(10).pow(decimals))
}

module.exports = {
  getCreate2CohortAddress,
  getBigNumber
}
