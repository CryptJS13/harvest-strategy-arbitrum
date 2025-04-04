// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./interface/IERC4626.sol";
import "./VaultV1.sol";

contract VaultV2 is IERC4626, VaultV1 {

    /// By default, the constant `10` is a uint8. This implicitly converts it to `uint256`
    uint256 public constant TEN = 10;

    function asset() public view override returns (address) {
        return underlying();
    }

    function totalAssets() public view override returns (uint256) {
        return underlyingBalanceWithInvestment();
    }

    function assetsPerShare() public view override returns (uint256) {
        return convertToAssets(TEN ** decimals());
    }

    function assetsOf(address _depositor) public view override returns (uint256) {
        return totalAssets() * balanceOf(_depositor) / totalSupply();
    }

    function maxDeposit(address /*caller*/) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 _assets) public view override returns (uint256) {
        return convertToShares(_assets);
    }

    function deposit(uint256 _assets, address _receiver) public override nonReentrant defense returns (uint256) {
        uint256 shares = _deposit(_assets, msg.sender, _receiver);
        return shares;
    }

    function maxMint(address /*caller*/) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 _shares) public view override returns (uint256) {
        return convertToAssets(_shares);
    }

    function mint(uint256 _shares, address _receiver) public override nonReentrant defense returns (uint256) {
        uint assets = convertToAssets(_shares);
        _deposit(assets, msg.sender, _receiver);
        return assets;
    }

    function maxWithdraw(address _caller) public view override returns (uint256) {
        return assetsOf(_caller);
    }

    function previewWithdraw(uint256 _assets) public view override returns (uint256) {
        return convertToShares(_assets);
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    )
    public override
    nonReentrant
    defense
    returns (uint256) {
        uint256 shares = convertToShares(_assets);
        _withdraw(shares, _receiver, _owner);
        return shares;
    }

    function maxRedeem(address _caller) public view override returns (uint256) {
        return balanceOf(_caller);
    }

    function previewRedeem(uint256 _shares) public view override returns (uint256) {
        return convertToAssets(_shares);
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
    public override
    nonReentrant
    defense
    returns (uint256) {
        uint256 assets = _withdraw(_shares, _receiver, _owner);
        return assets;
    }

    // ========================= Conversion Functions =========================

    function convertToAssets(uint256 _shares) public view returns (uint256) {
        return totalAssets() == 0 || totalSupply() == 0
            ? _shares * (TEN ** ERC20Upgradeable(underlying()).decimals()) / (TEN ** decimals())
            : _shares * totalAssets() / totalSupply();
    }

    function convertToShares(uint256 _assets) public view returns (uint256) {
        return totalAssets() == 0 || totalSupply() == 0
            ? _assets * (TEN ** decimals()) / (TEN ** ERC20Upgradeable(underlying()).decimals())
            : _assets * totalSupply() / totalAssets();
    }
}
