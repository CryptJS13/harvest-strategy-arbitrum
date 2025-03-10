//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IClearing {
  function getSqrtTwapX96(address, uint32) external view returns(uint160);
  function getDepositAmount(address, address, uint256) external view returns(uint256, uint256);
}