// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IVaultGMX.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/gmx/IMarket.sol";
import "../../base/interface/gmx/IExchangeRouter.sol";
import "../../base/interface/gmx/ICallbackReceiver.sol";
import "../../base/interface/gmx/IRoleStore.sol";
import "../../base/interface/gmx/IGMXViewer.sol";

// import "hardhat/console.sol";

contract GMXStrategy is BaseUpgradeableStrategy, ICallbackReceiver {

  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address public constant harvestMSIG = address(0xf3D1A027E858976634F81B7c41B09A05A46EdA21);

  // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
  bytes32 internal constant _EXCHANGE_ROUTER_SLOT = 0x37102ee245290fca7b7083aa93785ed04d2277eb4da3e0f305fc09592036c401;
  bytes32 internal constant _MARKET_SLOT = 0x7e894854bb2aa938fcac0eb9954ddb51bd061fc228fb4e5b8e859d96c06bfaa0;
  bytes32 internal constant _DEPOSIT_VAULT_SLOT = 0xb0598bc38333ab6eeb7272aded2335ca73c3fd494cec5ce1f0849cce000c3925;
  bytes32 internal constant _WITHDRAW_VAULT_SLOT = 0x65c967117bb0f9ef871538fd2bba12ca5f9d9ffa82f6b0f94c7f86b0c1575d56;
  bytes32 internal constant _VIEWER_SLOT = 0xe73eae2b084bf3db1612fa5a6e359b575d495e1d242881a0b5eb2c190b98da89;
  bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
  bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

  struct PendingDeposit {
    uint256 amountIn;
    uint256 expectedOut;
    uint256 underlyingBalance;
    uint256 marketBalance;
  }

  struct PendingWithdrawal {
    uint256 amountIn;
    uint256 expectedOut;
    uint256 underlyingBalance;
    uint256 marketBalance;
    bool isFee;
    bool withdrawAll;
  }

  uint256 internal underlyingInPending;
  uint256 internal marketInPending;
  uint256 internal txGasValue = 2e16;

  mapping (bytes32 => PendingDeposit) public pendingDeposits;
  mapping (bytes32 => PendingWithdrawal) public pendingWithdrawals;

  modifier onlyGmxKeeperOrGovernance() {
    address roleStore = IMarket(market()).roleStore();
    require(IRoleStore(roleStore).hasRole(msg.sender, keccak256(abi.encode("CONTROLLER"))) || msg.sender == governance());
    _;
  }

  constructor() BaseUpgradeableStrategy() {
    assert(_EXCHANGE_ROUTER_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.exchangeRouter")) - 1));
    assert(_MARKET_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.market")) - 1));
    assert(_DEPOSIT_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.depositVault")) - 1));
    assert(_WITHDRAW_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.withdrawVault")) - 1));
    assert(_VIEWER_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.viewer")) - 1));
    assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
  }

  function initializeBaseStrategy(
    address _storage,
    address _underlying,
    address _vault,
    address _exchangeRouter,
    address _market,
    address _depositVault,
    address _withdrawVault,
    address _viewer
  )
  public initializer {
    BaseUpgradeableStrategy.initialize(
      _storage,
      _underlying,
      _vault,
      _market,
      _underlying,
      harvestMSIG
    );

    _setMarket(_market);
    setAddress(_EXCHANGE_ROUTER_SLOT, _exchangeRouter);
    _setDepositVault(_depositVault);
    _setWithdrawVault(_withdrawVault);
    _setViewer(_viewer);
  }

  function investedUnderlyingBalance() public view returns (uint256) {
    uint256 underlyingBalance = IERC20(underlying()).balanceOf(address(this)).add(underlyingInPending);
    return underlyingBalance.add(storedBalance()).sub(pendingFee());
  }

  function currentBalance() public view returns (uint256) {
    address _market = market();
    uint256 balanceInMarket = IGMXViewer(viewer()).getWithdrawalAmountOut(
      _market,
      IERC20(_market).balanceOf(address(this)).add(marketInPending),
      false
    );
    return balanceInMarket;
  }

  function storedBalance() public view returns (uint256) {
    return getUint256(_STORED_SUPPLIED_SLOT);
  }

  function _updateStoredBalance() internal {
    uint256 balance = currentBalance();
    setUint256(_STORED_SUPPLIED_SLOT, balance);
  }

  function totalFeeNumerator() public view returns (uint256) {
    return strategistFeeNumerator().add(platformFeeNumerator()).add(profitSharingNumerator());
  }

  function pendingFee() public view returns (uint256) {
    return getUint256(_PENDING_FEE_SLOT);
  }

  function _accrueFee() internal {
    uint256 fee;
    if (currentBalance() > storedBalance()) {
      fee = currentBalance().sub(storedBalance()).mul(totalFeeNumerator()).div(feeDenominator());
    }
    setUint256(_PENDING_FEE_SLOT, pendingFee().add(fee));
  }

  function _handleFee() internal {
    _accrueFee();
    uint256 fee = pendingFee();
    if (fee > 10) {
      if (fee > IERC20(underlying()).balanceOf(address(this))) {
        uint256 toWithdraw = IERC20(market()).balanceOf(address(this))
          .mul(fee)
          .div(investedUnderlyingBalance());
        _withdraw(toWithdraw, true, false);
      } else {
        _notifyProfitInRewardToken(underlying(), fee.mul(feeDenominator()).div(totalFeeNumerator()));
        setUint256(_PENDING_FEE_SLOT, 0);
      }
    }
    _updateStoredBalance();
  }

  function depositArbCheck() public pure returns (bool) {
    // there's no arb here.
    return true;
  }

  /**
  * The strategy invests by supplying the underlying as a collateral.
  */
  function _investAllUnderlying() internal onlyNotPausedInvesting returns(bytes32) {
    uint256 underlyingBalance = IERC20(underlying()).balanceOf(address(this));
    bytes32 depositHash;
    if (underlyingBalance > 0) {
      depositHash = _deposit(underlyingBalance);
    }
    return depositHash;
  }

  function withdrawAllToVault() public restricted returns (bytes32) {
    _handleFee();
    address _market = market();
    bytes32 withdrawal;
    if (IERC20(_market).balanceOf(address(this)) > 0) {
      withdrawal = _withdraw(IERC20(_market).balanceOf(address(this)), false, true);
    }
    _updateStoredBalance();
    return withdrawal;
  }

  function withdrawToVault(uint256 amountUnderlying) public restricted returns(bytes32) {
    _accrueFee();
    address _underlying = underlying();
    uint256 balance = IERC20(_underlying).balanceOf(address(this));
    if (amountUnderlying <= balance) {
      IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
      return bytes32(0);
    }
    uint256 toWithdraw = IERC20(market()).balanceOf(address(this))
      .mul(amountUnderlying)
      .div(investedUnderlyingBalance().sub(balance));
    // get some of the underlying
    bytes32 withdrawal = _withdraw(toWithdraw, false, false);
    _updateStoredBalance();
    return withdrawal;
  }

  function doHardWork() public restricted returns(bytes32) {
    _handleFee();
    bytes32 depositHash = _investAllUnderlying();
    _updateStoredBalance();
    return depositHash;
  }

  /**
  * Salvages a token.
  */
  function salvage(address payable recipient, address token, uint256 amount) public onlyGovernance {
    if (token == address(0)) {
      recipient.transfer(amount);
    } else {
      IERC20(token).safeTransfer(recipient, amount);
    }
  }

  function _deposit(uint256 amount) internal returns(bytes32) {
    // console.log("Depositing", amount);
    address _market = market();
    address _underlying = underlying();
    address _depositVault = depositVault();
    address _exchangeRouter = exchangeRouter();
    uint256 expectedOut = IGMXViewer(viewer()).getDepositAmountOut(_market, amount, true);
    // console.log("Expected", expectedOut);
    bytes[] memory data = new bytes[](3);
    data[0] = abi.encodeWithSelector(
      IExchangeRouter.sendWnt.selector,
      _depositVault,
      txGasValue
    );
    data[1] = abi.encodeWithSelector(
      IExchangeRouter.sendTokens.selector,
      _underlying,
      _depositVault,
      amount
    );
    data[2] = abi.encodeWithSelector(
      IExchangeRouter.createDeposit.selector,
      IExchangeRouter.CreateDepositParams({
        receiver: address(this), //receiver
        callbackContract: address(this), //callbackContract
        uiFeeReceiver: address(0), //uiFeeReceiver
        market: _market, //market
        initialLongToken: _underlying, //initialLongToken
        initialShortToken: _underlying, //initialShortToken
        longTokenSwapPath: new address[](0), //longTokenSwapPath
        shortTokenSwapPath: new address[](0), //shortTokenSwapPath
        minMarketTokens: expectedOut.mul(999).div(1000), //minMarketTokens
        shouldUnwrapNativeToken: false, //shouldUnwrapNativeToken
        executionFee: txGasValue, //executionFee
        callbackGasLimit: 1e6 //callbackGasLimit
      })
    );
    IERC20(_underlying).safeApprove(address(0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6), 0);
    IERC20(_underlying).safeApprove(address(0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6), amount);
    bytes[] memory results = IExchangeRouter(_exchangeRouter).multicall{value: txGasValue}(data);
    // console.logBytes(results[2]);

    underlyingInPending += amount;
    pendingDeposits[bytes32(results[2])] = PendingDeposit(
      amount,
      expectedOut,
      IERC20(_underlying).balanceOf(address(this)),
      IERC20(_market).balanceOf(address(this))
    );
    return bytes32(results[2]);
  }

  function _withdraw(uint256 amount, bool isFee, bool withdrawAll) internal returns(bytes32) {
    // console.log("Withdrawing", amount);
    address _market = market();
    address _withdrawVault = withdrawVault();
    address _exchangeRouter = exchangeRouter();
    uint256 expectedOut = IGMXViewer(viewer()).getWithdrawalAmountOut(_market, amount, true);
    // console.log("Expected", expectedOut);
    bytes[] memory data = new bytes[](3);
    data[0] = abi.encodeWithSelector(
      IExchangeRouter.sendWnt.selector,
      _withdrawVault,
      txGasValue
    );
    data[1] = abi.encodeWithSelector(
      IExchangeRouter.sendTokens.selector,
      _market,
      _withdrawVault,
      amount
    );
    data[2] = abi.encodeWithSelector(
      IExchangeRouter.createWithdrawal.selector,
      IExchangeRouter.CreateWithdrawalParams({
        receiver: address(this), //receiver
        callbackContract: address(this), //callbackContract
        uiFeeReceiver: address(0), //uiFeeReceiver
        market: _market, //market
        longTokenSwapPath: new address[](0), //longTokenSwapPath
        shortTokenSwapPath: new address[](0), //shortTokenSwapPath
        minLongTokenAmount: expectedOut.mul(4995).div(10000), //minLongTokenAmount
        minShortTokenAmount: expectedOut.mul(4995).div(10000), //minShortTokenAmount
        shouldUnwrapNativeToken: false, //shouldUnwrapNativeToken
        executionFee: txGasValue, //executionFee
        callbackGasLimit: 1e6 //callbackGasLimit
      })
    );
    IERC20(_market).safeApprove(address(0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6), 0);
    IERC20(_market).safeApprove(address(0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6), amount);
    bytes[] memory results = IExchangeRouter(_exchangeRouter).multicall{value: txGasValue}(data);
    // console.logBytes(results[2]);

    marketInPending += amount;
    pendingWithdrawals[bytes32(results[2])] = PendingWithdrawal(
      amount,
      expectedOut,
      IERC20(underlying()).balanceOf(address(this)),
      IERC20(_market).balanceOf(address(this)),
      isFee,
      withdrawAll
    );
    return bytes32(results[2]);
  }

  function afterDepositExecution(
    bytes32 key, DepositProps memory deposit, EventUtils.EventLogData memory
  ) override external onlyGmxKeeperOrGovernance nonReentrant {
    // console.log("Deposit made:");
    // console.logBytes32(key);
    // console.log("MarketBalance:    ", IERC20(market()).balanceOf(address(this)));
    // console.log("UnderlyingBalance:", IERC20(underlying()).balanceOf(address(this)));

    uint256 depAmt = deposit.numbers.initialLongTokenAmount;
    uint256 received = IERC20(market()).balanceOf(address(this)).sub(pendingDeposits[key].marketBalance);
    // uint256 ratio = depAmt.mul(1e24).div(received);
    // console.log("Ratio:         ", ratio);
    // console.log("Expected Ratio:", depAmt.mul(1e24).div(pendingDeposits[key].expectedOut));
    // console.log("Diff:          ", ratio.mul(1e6).div(depAmt.mul(1e24).div(pendingDeposits[key].expectedOut)));

    uint256 correctedAmount = depAmt.mul(received).div(pendingDeposits[key].expectedOut);
    // console.log(depAmt, correctedAmount);

    IVaultGMX.PendingAction memory pending = IVaultGMX(vault()).pendingDeposits(key);
    if (pending.pending) {
      IVaultGMX(vault()).finalizeDeposit(true, key, correctedAmount);
    }
    underlyingInPending -= depAmt;
    pendingDeposits[key] = PendingDeposit(0, 0, 0, 0);
    _updateStoredBalance();
  }

  function afterDepositCancellation(
    bytes32 key, DepositProps memory deposit, EventUtils.EventLogData memory
  ) override external onlyGmxKeeperOrGovernance nonReentrant {
    IVaultGMX.PendingAction memory pending = IVaultGMX(vault()).pendingDeposits(key);
    if (pending.pending) {
      IERC20(underlying()).safeTransfer(vault(), deposit.numbers.initialLongTokenAmount);
      IVaultGMX(vault()).finalizeDeposit(false, key, 0);
    }
    underlyingInPending -= deposit.numbers.initialLongTokenAmount;
    pendingDeposits[key] = PendingDeposit(0, 0, 0, 0);
    _updateStoredBalance();
  }

  function afterWithdrawalExecution(
    bytes32 key, WithdrawalProps memory withdrawal, EventUtils.EventLogData memory
  ) override external onlyGmxKeeperOrGovernance nonReentrant {
    // console.log("Withdrawal made:");
    // console.logBytes32(key);
    // console.log("MarketBalance:    ", IERC20(market()).balanceOf(address(this)));
    // console.log("UnderlyingBalance:", IERC20(underlying()).balanceOf(address(this)));

    uint256 withAmt = withdrawal.numbers.marketTokenAmount;
    uint256 received = pendingWithdrawals[key].withdrawAll ? 
      IERC20(underlying()).balanceOf(address(this)) : 
      IERC20(underlying()).balanceOf(address(this)).sub(pendingWithdrawals[key].underlyingBalance);
    // uint256 ratio = received.mul(1e24).div(withAmt);
    // console.log("Ratio:         ", ratio);
    // console.log("Expected Ratio:", pendingWithdrawals[key].expectedOut.mul(1e24).div(withAmt));
    // console.log("Diff:          ", ratio.mul(1e6).div(pendingWithdrawals[key].expectedOut.mul(1e24).div(withAmt)));

    if (pendingWithdrawals[key].isFee) {
      uint256 balanceIncrease;
      uint256 _pendingFee = pendingFee();
      uint256 remainingFee;
      if (received < _pendingFee) {
        balanceIncrease = received.mul(feeDenominator()).div(totalFeeNumerator());
        remainingFee = _pendingFee.sub(received);
      } else {
        balanceIncrease = _pendingFee.mul(feeDenominator()).div(totalFeeNumerator());
        remainingFee = 0;
      }      
      _notifyProfitInRewardToken(underlying(), balanceIncrease);
      setUint256(_PENDING_FEE_SLOT, remainingFee);

      marketInPending -= withAmt;
      pendingWithdrawals[key] = PendingWithdrawal(0, 0, 0, 0, false, false);
      _updateStoredBalance();
    } else {
      IERC20(underlying()).safeTransfer(vault(), received);
      
      IVaultGMX.PendingAction memory pending = IVaultGMX(vault()).pendingWithdrawals(key);
      if (pending.pending) {
        IVaultGMX(vault()).finalizeWithdrawal(true, key, received);
      }
      marketInPending -= withAmt;
      pendingWithdrawals[key] = PendingWithdrawal(0, 0, 0, 0, false, false);
      _updateStoredBalance();
    }
  }

  function afterWithdrawalCancellation(
    bytes32 key, WithdrawalProps memory withdrawal, EventUtils.EventLogData memory
  ) override external onlyGmxKeeperOrGovernance nonReentrant {
    IVaultGMX.PendingAction memory pending = IVaultGMX(vault()).pendingWithdrawals(key);
    if (pending.pending) {
      IVaultGMX(vault()).finalizeWithdrawal(false, key, 0);
    }
    marketInPending -= withdrawal.numbers.marketTokenAmount;
    pendingWithdrawals[key] = PendingWithdrawal(0, 0, 0, 0, false, false);
    _updateStoredBalance();
  }


  function _setMarket (address _target) internal {
    setAddress(_MARKET_SLOT, _target);
  }

  function market() public view returns (address) {
    return getAddress(_MARKET_SLOT);
  }

  function setExchangeRouter(address _target) external onlyGovernance {
    setAddress(_EXCHANGE_ROUTER_SLOT, _target);
  }

  function exchangeRouter() public view returns (address) {
    return getAddress(_EXCHANGE_ROUTER_SLOT);
  }

  function _setDepositVault(address _target) internal {
    setAddress(_DEPOSIT_VAULT_SLOT, _target);
  }

  function depositVault() internal view returns (address) {
    return getAddress(_DEPOSIT_VAULT_SLOT);
  }

  function _setWithdrawVault(address _target) internal {
    setAddress(_WITHDRAW_VAULT_SLOT, _target);
  }

  function withdrawVault() internal view returns (address) {
    return getAddress(_WITHDRAW_VAULT_SLOT);
  }

  function _setViewer(address _target) internal {
    setAddress(_VIEWER_SLOT, _target);
  }

  function viewer() internal view returns (address) {
    return getAddress(_VIEWER_SLOT);
  }

  function setGasValue(uint256 value) external onlyGovernance {
    txGasValue = value;
  }

  function finalizeUpgrade() external onlyGovernance {
    _finalizeUpgrade();
  }

  receive() external payable {}
}