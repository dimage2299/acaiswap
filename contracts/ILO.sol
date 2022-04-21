// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
import "./AcaiToken.sol";
import "./SafeTransferEth.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ILO is Ownable {
    LiquidityManager public liquidityManager;
    AcaiToken public rewardToken;
    IERC20 public inputToken;
    uint public rewardBalance;
    uint public startTime;
    uint public duration;
    uint public endTime;
    //in basis points, ie. 10000 -> 100% bonus
    uint public linearBonusCoefficient;
    uint constant bonusCoefficientDivisor = 10000;
    uint public minimumEthAmount;
    uint public lastPriceScaled;

    bool public manualRefundActive = false;
    bool internal initialized = false;
    bool internal poolCreated = false;

    mapping(address => uint) public providedEth;
    uint public totalProvidedEth;
    //includes linear time bonus
    mapping(address => uint) public effectiveEth;
    uint public totalEffectiveEth;

    uint public userCount;
    uint public claimedCount;

    event Payment(address indexed from, uint ethAmount);
    event Claim(address indexed to, uint tokenAmount);
    event Refund(address indexed to, uint ethAmount);
    event RefundsEnabled();

    modifier isInitialized() {
        require(initialized, 'not initialized');
        _;
    }

    function initialize(LiquidityManager _liquidityManager, AcaiToken _rewardToken, IERC20 _inputToken, uint _rewardBalance, uint _startTime, uint _duration, uint _minimumAmount, uint _linearBonusCoefficient) external onlyOwner {
        require(!initialized, 'already initialized');
        liquidityManager = _liquidityManager;
        inputToken = _inputToken;
        rewardToken = _rewardToken;
        rewardBalance = _rewardBalance;
        require(rewardToken.balanceOf(address(this)) >= _rewardBalance, 'rewardToken balance too low');

        require(block.timestamp <= _startTime, 'start time is in the past');
        startTime = _startTime;
        duration = _duration;
        endTime = _startTime + _duration;
        minimumEthAmount = _minimumAmount;
        linearBonusCoefficient = _linearBonusCoefficient;

        initialized = true;
    }

    function deinit() external onlyOwner isInitialized {
        require(block.timestamp < startTime);
        initialized = false;
    }

    function getEffectiveEth(uint amount) public view returns (uint) {
        uint remainingSeconds = endTime - block.timestamp;
        return amount+amount*linearBonusCoefficient*remainingSeconds/(duration*bonusCoefficientDivisor);
    }

    function pay(uint amount) external isInitialized returns (uint, uint) {
        require(amount > 1024, "not enough ETH provided");
        require(startTime <= block.timestamp, "ILO didn't start yet");
        require(block.timestamp < endTime, 'ILO has ended');
        require(!manualRefundActive, 'Emergency refund active');

        if(providedEth[msg.sender] == 0) {
            userCount++;
        }
        providedEth[msg.sender] += amount;
        totalProvidedEth += amount;
        uint _effectiveEth = getEffectiveEth(amount);
        effectiveEth[msg.sender] += _effectiveEth;
        totalEffectiveEth += _effectiveEth;
        inputToken.transferFrom(msg.sender, address(this), amount);

        uint tokensAcquiredNowAtCurrentPrice = rewardBalance*_effectiveEth/totalEffectiveEth;
        lastPriceScaled = amount*totalEffectiveEth/_effectiveEth;
        emit Payment(msg.sender, amount);
        return (_effectiveEth, totalEffectiveEth);
    }

    function refund() external isInitialized returns (uint refundAmount) {
        //refund manually enabled, or ILO has ended, but minimum amount not met
        require(manualRefundActive || (block.timestamp >= endTime && totalProvidedEth < minimumEthAmount), 'refund conditions not met');
        require(!poolCreated); //this should never happen
        refundAmount = providedEth[msg.sender];
        providedEth[msg.sender] = 0;
        effectiveEth[msg.sender] = 0;
        inputToken.transfer(msg.sender, refundAmount);
        emit Refund(msg.sender, refundAmount);
    }

    //returns current token amount, assuming no further eth are provided
    function getCurrentTokenAmount(address account) public view returns (uint) {
        return rewardBalance*effectiveEth[account]/totalEffectiveEth;
    }

    function claim() external isInitialized returns (uint) {
        require(poolCreated, 'claims not active');
        uint claimAmount = getCurrentTokenAmount(msg.sender);
        require(claimAmount != 0, 'no claim');
        providedEth[msg.sender] = 0;
        effectiveEth[msg.sender] = 0;
        claimedCount++;
        rewardToken.transfer(msg.sender, claimAmount);
        emit Claim(msg.sender, claimAmount);
        return claimAmount;
    }

    function spawnPool() external isInitialized {
        require(!poolCreated, 'pool already exists');
        require(!manualRefundActive, 'manual refund is active');
        require(block.timestamp >= endTime, 'ILO still active');
        require(totalProvidedEth >= minimumEthAmount, 'Minimum eth not met');
        uint tokensNeededForLiquidity = totalProvidedEth*rewardBalance/lastPriceScaled;
        rewardToken.manualMint(address(liquidityManager), tokensNeededForLiquidity);
        inputToken.transfer(address(liquidityManager), totalProvidedEth);
        liquidityManager.createPool(tokensNeededForLiquidity, totalProvidedEth);
        poolCreated = true;
    }

    function enableRefunds() external onlyOwner isInitialized {
        require(startTime <= block.timestamp, 'ilo not started');
        manualRefundActive = true;
        rewardToken.transfer(msg.sender, rewardToken.balanceOf(address(this)));
        emit RefundsEnabled();
    }

    function failsafeWithdrawEth() external onlyOwner {
        SafeTransferEth.transferEth(msg.sender, address(this).balance);
    }

    function failsafeWithdrawToken(IERC20 _token, address recipient, uint amount) external onlyOwner returns (uint) {
        if(amount == 0) {
            amount = _token.balanceOf(address(this));
        }
        SafeERC20.safeTransfer(_token, recipient, amount);
        return amount;
    }
}