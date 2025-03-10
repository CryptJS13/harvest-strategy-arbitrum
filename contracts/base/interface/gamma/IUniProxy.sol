//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

interface IUniProxy {
  function deposit(
    uint256 deposit0,
    uint256 deposit1,
    address to,
    address pos,
    uint256[4] memory minIn
  ) external;
  function getSqrtTwapX96(address, uint32) external view returns(uint160);
  function clearance() external view returns(address);
}