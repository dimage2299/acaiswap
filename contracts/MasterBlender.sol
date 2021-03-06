// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AcaiToken.sol";
import "./Authorizable.sol";

// MasterBlender is the master blender of whatever farms are available.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ACAI is sufficiently
// distributed and the community can show to govern itself.
//
contract MasterBlender is Ownable, Authorizable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardDebtAtBlock; // the last block user stake
        uint256 lastWithdrawBlock; // the last block a user withdrew at.
        uint256 firstDepositBlock; // the last block a user deposited at.
        uint256 blockdelta; //time passed since withdrawals
        uint256 lastDepositBlock;
        //
        // We do some fancy math here. Basically, at any point in time, the
        // amount of ACAI
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGovTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGovTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ACAI to distribute per block.
        uint256 lastRewardBlock; // Last block number that ACAI distribution occurs.
        uint256 accGovTokenPerShare; // Accumulated ACAI per share, times 1e12. See below.
    }

    // The ACAI token
    AcaiToken public govToken;
    // Dev address.
    address public devaddr;
    // ACAI created per block.
    uint256 public REWARD_PER_BLOCK;
    // Bonus multiplier for early ACAI makers.
    uint256[] public REWARD_MULTIPLIER; // init in constructor function
    uint256[] public HALVING_AT_BLOCK; // init in constructor function
    uint256[] public blockDeltaStartStage;
    uint256[] public blockDeltaEndStage;
    uint256[] public userFeeStage;
    uint256[] public devFeeStage;
    uint256 public FINISH_BONUS_AT_BLOCK;

    // The block number when ACAI mining starts.
    uint256 public START_BLOCK;

    uint256[] public PERCENT_LOCK_BONUS_REWARD; // lock xx% of bounus reward

    // Info of each pool.
    PoolInfo[] public poolInfo;
    mapping(address => uint256) public poolId1; // poolId1 starting from 1, subtract 1 before using with poolInfo
    // Info of each user that stakes LP tokens. pid => user address => info
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(IERC20 => bool) public poolExistence;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SendGovernanceTokenReward(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 lockAmount
    );

    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "MasterBlender::nonDuplicated: duplicated");
        _;
    }

    constructor(
        AcaiToken _govToken,
        address _devaddr,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _halvingAfterBlock,
        uint256[] memory _rewardMultiplier,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage,
        uint256[] memory _devFeeStage
    ) public {
        govToken = _govToken;
        devaddr = _devaddr;
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        REWARD_MULTIPLIER = _rewardMultiplier;
        blockDeltaStartStage = _blockDeltaStartStage;
        blockDeltaEndStage = _blockDeltaEndStage;
        userFeeStage = _userFeeStage;
        devFeeStage = _devFeeStage;
        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtBlock = _halvingAfterBlock.mul(i+1).add(_startBlock).add(1);
            HALVING_AT_BLOCK.push(halvingAtBlock);
        }
        FINISH_BONUS_AT_BLOCK = _halvingAfterBlock
            .mul(REWARD_MULTIPLIER.length - 1)
            .add(_startBlock);
        HALVING_AT_BLOCK.push(uint256(-1));
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(
            poolId1[address(_lpToken)] == 0,
            "MasterBlender::add: lp is already in pool"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > START_BLOCK ? block.number : START_BLOCK;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolId1[address(_lpToken)] = poolInfo.length + 1;
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accGovTokenPerShare: 0
            })
        );
    }

    // Update the given pool's ACAI allocation points. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 GovTokenForFarmer =  getPoolReward(pool.lastRewardBlock, block.number, pool.allocPoint);
        // Mint some new ACAI tokens for the farmer and store them in MasterBlender.
        govToken.mint(address(this), GovTokenForFarmer);
        pool.accGovTokenPerShare = pool.accGovTokenPerShare.add(
            GovTokenForFarmer.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // |--------------------------------------|
    // [20, 30, 40, 50, 60, 70, 80, 99999999]
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 0;

        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];
            if (i > REWARD_MULTIPLIER.length-1) return 0;

            if (_to <= endBlock) {
                uint256 m = _to.sub(_from).mul(REWARD_MULTIPLIER[i]);
                return result.add(m);
            }

            if (_from < endBlock) {
                uint256 m = endBlock.sub(_from).mul(REWARD_MULTIPLIER[i]);
                _from = endBlock;
                result = result.add(m);
            }
        }

        return result;
    }

    function getLockPercentage(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 100;

        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];
            if (i > PERCENT_LOCK_BONUS_REWARD.length-1) return 0;

            if (_to <= endBlock) {
                return PERCENT_LOCK_BONUS_REWARD[i];
            }
        }

        return result;
    }

    function getPoolReward(
        uint256 _from,
        uint256 _to,
        uint256 _allocPoint
    )
        public
        view
        returns (
            uint256 forFarmer
        )
    {
        uint256 multiplier = getMultiplier(_from, _to);
        uint256 amount =
            multiplier.mul(REWARD_PER_BLOCK).mul(_allocPoint).div(
                totalAllocPoint
            );
        uint256 GovernanceTokenCanMint = govToken.cap().sub(govToken.totalSupply());

        if (GovernanceTokenCanMint < amount) {
            // If there aren't enough governance tokens left to mint before the cap,
            // just give all of the possible tokens left to the farmer.
            forFarmer = GovernanceTokenCanMint;
        } else {
            // Otherwise, give the farmer their full amount 
            forFarmer = amount;
        }
    }

    // View function to see pending ACAI on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGovTokenPerShare = pool.accGovTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply > 0) {
            uint256 GovTokenForFarmer = getPoolReward(
                pool.lastRewardBlock,
                block.number,
                pool.allocPoint
            );
            accGovTokenPerShare = accGovTokenPerShare.add(
                GovTokenForFarmer.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accGovTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    function claimRewards(uint256[] memory _pids) public {
        for (uint256 i = 0; i < _pids.length; i++) {
          claimReward(_pids[i]);
        }
    }

    function claimReward(uint256 _pid) public {
        updatePool(_pid);
        _harvest(_pid);
    }

    // lock a % of reward if it comes from bonus time.
    function _harvest(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Only harvest if the user amount is greater than 0.
        if (user.amount > 0) {
            // Calculate the pending reward. This is the user's amount of LP
            // tokens multiplied by the accGovTokenPerShare of the pool, minus
            // the user's rewardDebt.
            uint256 pending =
                user.amount.mul(pool.accGovTokenPerShare).div(1e12).sub(
                    user.rewardDebt
                );

            // Make sure we aren't giving more tokens than we have in the
            // MasterBlender contract.
            uint256 masterBal = govToken.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }

            if (pending > 0) {
                // If the user has a positive pending balance of tokens, transfer
                // those tokens from MasterBlender to their wallet.
                govToken.transfer(msg.sender, pending);
                uint256 lockAmount = 0;
                if (user.rewardDebtAtBlock <= FINISH_BONUS_AT_BLOCK) {
                    // If we are before the FINISH_BONUS_AT_BLOCK number, we need
                    // to lock some of those tokens, based on the current lock
                    // percentage of their tokens they just received.
                    uint256 lockPercentage = getLockPercentage(block.number - 1, block.number);
                    lockAmount = pending.mul(lockPercentage).div(100);
                    govToken.lock(msg.sender, lockAmount);
                }

                // Reset the rewardDebtAtBlock to the current block for the user.
                user.rewardDebtAtBlock = block.number;

                emit SendGovernanceTokenReward(msg.sender, _pid, pending, lockAmount);
            }

            // Recalculate the rewardDebt for the user.
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
        }
    }


    // Deposit LP tokens to MasterBlender for ACAI allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        require(
            _amount > 0,
            "MasterBlender::deposit: amount must be greater than 0"
        );

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        // When a user deposits, we need to update the pool and harvest beforehand,
        // since the rates will change.
        updatePool(_pid);
        _harvest(_pid);
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        if (user.amount == 0) {
            user.rewardDebtAtBlock = block.number;
        }
        user.amount = user.amount.add(
            _amount
        );
        user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
        if (user.firstDepositBlock > 0) {} else {
            user.firstDepositBlock = block.number;
        }
        user.lastDepositBlock = block.number;
    }

    // Withdraw LP tokens from MasterBlender.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "MasterBlender: withdraw not good");

        updatePool(_pid);
        _harvest(_pid);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if (user.lastWithdrawBlock > 0) {
                user.blockdelta = block.number - user.lastWithdrawBlock;
            } else {
                user.blockdelta = block.number - user.firstDepositBlock;
            }
            if (
                user.blockdelta == blockDeltaStartStage[0] ||
                block.number == user.lastDepositBlock
            ) {
                //25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[0]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[0]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[1] &&
                user.blockdelta <= blockDeltaEndStage[0]
            ) {
                //8% fee if a user deposits and withdraws in between same block and 59 minutes.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[1]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[1]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[2] &&
                user.blockdelta <= blockDeltaEndStage[1]
            ) {
                //4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[2]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[2]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[3] &&
                user.blockdelta <= blockDeltaEndStage[2]
            ) {
                //2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[3]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[3]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[4] &&
                user.blockdelta <= blockDeltaEndStage[3]
            ) {
                //1% fee if a user deposits and withdraws after 3 days but before 5 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[4]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[4]).div(100)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[5] &&
                user.blockdelta <= blockDeltaEndStage[4]
            ) {
                //0.5% fee if a user deposits and withdraws if the user withdraws after 5 days but before 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[5]).div(1000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[5]).div(1000)
                );
            } else if (
                user.blockdelta >= blockDeltaStartStage[6] &&
                user.blockdelta <= blockDeltaEndStage[5]
            ) {
                //0.25% fee if a user deposits and withdraws after 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[6]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[6]).div(10000)
                );
            } else if (user.blockdelta > blockDeltaStartStage[7]) {
                //0.1% fee if a user deposits and withdraws after 4 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[7]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[7]).div(10000)
                );
            }
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
            emit Withdraw(msg.sender, _pid, _amount);
            user.lastWithdrawBlock = block.number;
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY. This has the same 25% fee as same block withdrawals to prevent abuse of thisfunction.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = user.amount.mul(75).div(100);
        uint256 devToSend = user.amount.mul(25).div(100);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amountToSend);
        pool.lpToken.safeTransfer(address(devaddr), devToSend);
        emit EmergencyWithdraw(msg.sender, _pid, amountToSend);
    }

    // Safe GovToken transfer function, just in case if rounding error causes pool to not have enough GovTokens.
    function safeGovTokenTransfer(address _to, uint256 _amount) internal {
        uint256 govTokenBal = govToken.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > govTokenBal) {
            transferSuccess = govToken.transfer(_to, govTokenBal);
        } else {
            transferSuccess = govToken.transfer(_to, _amount);
        }
        require(transferSuccess, "MasterBlender::safeGovTokenTransfer: transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public onlyAuthorized {
        devaddr = _devaddr;
    }

    // Update Finish Bonus Block
    function bonusFinishUpdate(uint256 _newFinish) public onlyAuthorized {
        FINISH_BONUS_AT_BLOCK = _newFinish;
    }

    // Update Halving At Block
    function halvingUpdate(uint256[] memory _newHalving) public onlyAuthorized {
        HALVING_AT_BLOCK = _newHalving;
    }

    // Update Reward Per Block
    function rewardUpdate(uint256 _newReward) public onlyAuthorized {
        REWARD_PER_BLOCK = _newReward;
    }

    // Update Rewards Mulitplier Array
    function rewardMulUpdate(uint256[] memory _newMulReward) public onlyAuthorized {
        REWARD_MULTIPLIER = _newMulReward;
    }

    // Update % lock for general users
    function lockUpdate(uint256[] memory _newlock) public onlyAuthorized {
        PERCENT_LOCK_BONUS_REWARD = _newlock;
    }

    // Update START_BLOCK
    function starblockUpdate(uint256 _newstarblock) public onlyAuthorized {
        START_BLOCK = _newstarblock;
    }

    function getNewRewardPerBlock(uint256 pid1) public view returns (uint256) {
        uint256 multiplier = getMultiplier(block.number - 1, block.number);
        if (pid1 == 0) {
            return multiplier.mul(REWARD_PER_BLOCK);
        } else {
            return
                multiplier
                    .mul(REWARD_PER_BLOCK)
                    .mul(poolInfo[pid1 - 1].allocPoint)
                    .div(totalAllocPoint);
        }
    }

    function userDelta(uint256 _pid) public view returns (uint256) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.lastWithdrawBlock > 0) {
            uint256 estDelta = block.number - user.lastWithdrawBlock;
            return estDelta;
        } else {
            uint256 estDelta = block.number - user.firstDepositBlock;
            return estDelta;
        }
    }

    function reviseWithdraw(uint256 _pid, address _user, uint256 _block) public onlyAuthorized() {
        UserInfo storage user = userInfo[_pid][_user];
        user.lastWithdrawBlock = _block;
    }

    function reviseDeposit(uint256 _pid, address _user, uint256 _block) public onlyAuthorized() {
        UserInfo storage user = userInfo[_pid][_user];
        user.firstDepositBlock = _block;
    }

    function setStageStarts(uint256[] memory _blockStarts) public onlyAuthorized() {
        blockDeltaStartStage = _blockStarts;
    }

    function setStageEnds(uint256[] memory _blockEnds) public onlyAuthorized() {
        blockDeltaEndStage = _blockEnds;
    }

    function setUserFeeStage(uint256[] memory _userFees) public onlyAuthorized() {
        userFeeStage = _userFees;
    }

    function setDevFeeStage(uint256[] memory _devFees) public onlyAuthorized() {
        devFeeStage = _devFees;
    }

    function reclaimTokenOwnership(address _newOwner) public onlyAuthorized() {
        govToken.transferOwnership(_newOwner);
    }
}