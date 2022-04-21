// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Authorizable.sol";

contract AcaiToken is ERC20, Ownable, Authorizable {
    uint256 private _cap;
    uint256 private _totalLock;
    uint256 public lockFromBlock;
    uint256 public lockToBlock;
    uint256 public manualMintLimit;
    uint256 public manualMinted = 0;

    mapping(address => uint256) private _locks;
    mapping(address => uint256) private _lastUnlockBlock;

    // Events.
    event Lock(address indexed to, uint256 value);
    event Unlock(address indexed to, uint256 value);

    constructor(
      string memory _name,
      string memory _symbol,
      uint256 cap_,
      uint256 _manualMintLimit,
      uint256 _lockFromBlock,
      uint256 _lockToBlock
    ) public ERC20(_name, _symbol) {
        _cap = cap_;
        manualMintLimit = _manualMintLimit;
        lockFromBlock = _lockFromBlock;
        lockToBlock = _lockToBlock;
    }

    /**
     * @dev Returns the cap on the token's total supply.
     */
    function cap() public view returns (uint256) {
        return _cap;
    }

    /**
     * @dev Updates the total cap.
     */
    function capUpdate(uint256 _newCap) public onlyAuthorized {
        _cap = _newCap;
    }
    
    // Update the lockFromBlock
    function lockFromUpdate(uint256 _newLockFrom) public onlyAuthorized {
        lockFromBlock = _newLockFrom;
    }

    // Update the lockToBlock
    function lockToUpdate(uint256 _newLockTo) public onlyAuthorized {
        lockToBlock = _newLockTo;
    }

    function unlockedSupply() public view returns (uint256) {
        return totalSupply().sub(_totalLock);
    }

    function lockedSupply() public view returns (uint256) {
        return totalLock();
    }

    function circulatingSupply() public view returns (uint256) {
        return totalSupply();
    }

    function totalLock() public view returns (uint256) {
        return _totalLock;
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - minted tokens must not cause the total supply to go over the cap.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0)) {
            // When minting tokens
            require(
                totalSupply().add(amount) <= _cap,
                "ERC20Capped: cap exceeded"
            );
        }
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        super._transfer(sender, recipient, amount);
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterGardener).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    function manualMint(address _to, uint256 _amount) public onlyAuthorized {
        require(manualMinted < manualMintLimit, "Exceeded manual mint limit");
        _mint(_to, _amount);
        manualMinted = manualMinted.add(_amount);
    }

    function totalBalanceOf(address _holder) public view returns (uint256) {
        return _locks[_holder].add(balanceOf(_holder));
    }

    function lockOf(address _holder) public view returns (uint256) {
        return _locks[_holder];
    }

    function lastUnlockBlock(address _holder) public view returns (uint256) {
        return _lastUnlockBlock[_holder];
    }

    function lock(address _holder, uint256 _amount) public onlyAuthorized {
        require(_holder != address(0), "Cannot lock to the zero address");
        require(
            _amount <= balanceOf(_holder),
            "Lock amount over balance"
        );

        _transfer(_holder, address(this), _amount);

        _locks[_holder] = _locks[_holder].add(_amount);
        _totalLock = _totalLock.add(_amount);
        if (_lastUnlockBlock[_holder] < lockFromBlock) {
            _lastUnlockBlock[_holder] = lockFromBlock;
        }
        emit Lock(_holder, _amount);
    }

    function canUnlockAmount(address _holder) public view returns (uint256) {
        if (block.number < lockFromBlock) {
            return 0;
        } else if (block.number >= lockToBlock) {
            return _locks[_holder];
        } else {
            uint256 releaseBlock = block.number.sub(_lastUnlockBlock[_holder]);
            uint256 numberLockBlock =
                lockToBlock.sub(_lastUnlockBlock[_holder]);
            return _locks[_holder].mul(releaseBlock).div(numberLockBlock);
        }
    }

    // Unlocks some locked tokens immediately.
    function unlockForUser(address account, uint256 amount) public onlyAuthorized {
        // First we need to unlock all tokens the address is eligible for.
        uint256 pendingLocked = canUnlockAmount(account);
        if (pendingLocked > 0) {
            _unlock(account, pendingLocked);
        }

        // Now that that's done, we can unlock the extra amount passed in.
        _unlock(account, amount);
    }

    function unlock() public {
        uint256 amount = canUnlockAmount(msg.sender);
        _unlock(msg.sender, amount);
    }

    function _unlock(address holder, uint256 amount) internal {
        require(_locks[holder] > 0, "Insufficient locked tokens");

        // Make sure they aren't trying to unlock more than they have locked.
        if (amount > _locks[holder]) {
            amount = _locks[holder];
        }

        // If the amount is greater than the total balance, set it to max.
        if (amount > balanceOf(address(this))) {
            amount = balanceOf(address(this));
        }
        _transfer(address(this), holder, amount);
        _locks[holder] = _locks[holder].sub(amount);
        _lastUnlockBlock[holder] = block.number;
        _totalLock = _totalLock.sub(amount);

        emit Unlock(holder, amount);
    }
    
    /**
        @notice Burns tokens owned by msg.sender
        @param amount The amount to be burned
     */
    function burn(uint amount) external {
        _transfer(msg.sender, address(0), amount);
    }

    // This function is for dev address migrate all balance to a multi sig address
    function transferAll(address _to) public {
        _locks[_to] = _locks[_to].add(_locks[msg.sender]);

        if (_lastUnlockBlock[_to] < lockFromBlock) {
            _lastUnlockBlock[_to] = lockFromBlock;
        }

        if (_lastUnlockBlock[_to] < _lastUnlockBlock[msg.sender]) {
            _lastUnlockBlock[_to] = _lastUnlockBlock[msg.sender];
        }

        _locks[msg.sender] = 0;
        _lastUnlockBlock[msg.sender] = 0;

        _transfer(msg.sender, _to, balanceOf(msg.sender));
    }
}