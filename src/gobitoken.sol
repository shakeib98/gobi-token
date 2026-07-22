// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Snapshot.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import "openzeppelin/utils/Arrays.sol";

/// @title GobiToken
/// @notice GOBI ERC-20 with snapshots and an SFA §276 transfer lock.
/// @dev Category A eligibility is NOT a manual flag. It equals whatever a
/// wallet has received directly from the Sablier contract and not yet
/// spent. Tokens from any other source (public transfer, mint) are never
/// eligible for the subsidy, but they DO count toward base yield, and if
/// they land in a wallet that also holds eligible balance, the whole
/// wallet is locked (transfers blocked) until the lock-up expires.
/// Do not upgrade to OpenZeppelin v5 — ERC20Snapshot was removed there.
contract GobiToken is ERC20, ERC20Snapshot, AccessControl, ERC20Burnable {
    uint256 public constant MAX_SUPPLY = 1_200_000_000e18;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @dev Grant to the Adapter contract, not an EOA — it calls {snapshot}.
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    uint256 public constant LOCK_DURATION = 180 days;

    /// @notice Sablier V2 Lockup holding the private/advisor vesting streams.
    address public immutable sablierLockup;

    /// @notice Amount each wallet holds that came directly from Sablier.
    /// @dev Increases only on a transfer FROM sablierLockup. Decreases on
    /// any outgoing transfer/burn (debited first, floored at zero).
    mapping(address => uint256) public categoryAEligibleBalance;

    /// @notice Sum of {categoryAEligibleBalance} across all wallets.
    uint256 public categoryATotalSupply;

    /// @dev Checkpoint arrays mirroring ERC20Snapshot's own scheme.
    struct CatASnapshots {
        uint256[] ids;
        uint256[] values;
    }

    mapping(address => CatASnapshots) private _categoryABalanceSnapshots;
    CatASnapshots private _categoryATotalSupplySnapshots;

    /// @notice TGE timestamp; 0 = not set = lock-up fail-closed ACTIVE.
    uint256 public tgeTimestamp;

    event SnapshotTaken(uint256 indexed snapshotId);
    event CategoryABalanceChanged(address indexed account, uint256 newBalance);
    event TgeTimestampSet(uint256 timestamp);

    constructor(address multisig, address _sablierLockup) ERC20("Gobi Token", "GOBI") {
        require(multisig != address(0), "Multisig address cannot be zero");
        require(_sablierLockup != address(0), "Gobi: Sablier address cannot be zero");
        _grantRole(DEFAULT_ADMIN_ROLE, multisig);
        _grantRole(MINTER_ROLE, multisig);
        sablierLockup = _sablierLockup;
        _mint(multisig, 400_000_000e18);
    }

    /// @notice True while the SFA §276 lock is active.
    function lockupActive() public view returns (bool) {
        return tgeTimestamp == 0 || block.timestamp < tgeTimestamp + LOCK_DURATION;
    }

    /// @notice Whether `account` currently holds any eligible balance.
    function isCategoryA(address account) public view returns (bool) {
        return categoryAEligibleBalance[account] > 0;
    }

    /// @notice `account`'s eligible balance at snapshot `snapshotId`.
    function categoryABalanceAt(address account, uint256 snapshotId) public view returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _categoryABalanceSnapshots[account]);
        return snapshotted ? value : categoryAEligibleBalance[account];
    }

    /// @notice Total eligible supply at snapshot `snapshotId`.
    function categoryATotalSupplyAt(uint256 snapshotId) public view returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _categoryATotalSupplySnapshots);
        return snapshotted ? value : categoryATotalSupply;
    }

    function _valueAt(uint256 snapshotId, CatASnapshots storage snaps) private view returns (bool, uint256) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");
        uint256 index = Arrays.findUpperBound(snaps.ids, snapshotId);
        if (index == snaps.ids.length) return (false, 0);
        return (true, snaps.values[index]);
    }

    function _updateSnapshot(CatASnapshots storage snaps, uint256 currentValue) private {
        uint256 currentId = _getCurrentSnapshotId();
        uint256 last = snaps.ids.length == 0 ? 0 : snaps.ids[snaps.ids.length - 1];
        if (last < currentId) {
            snaps.ids.push(currentId);
            snaps.values.push(currentValue);
        }
    }

    /// @dev Moves eligible balance in/out of `account`, checkpointing first.
    function _adjustCategoryABalance(address account, bool increase, uint256 amount) private {
        if (amount == 0) return;
        _updateSnapshot(_categoryABalanceSnapshots[account], categoryAEligibleBalance[account]);
        _updateSnapshot(_categoryATotalSupplySnapshots, categoryATotalSupply);
        if (increase) {
            categoryAEligibleBalance[account] += amount;
            categoryATotalSupply += amount;
        } else {
            categoryAEligibleBalance[account] -= amount;
            categoryATotalSupply -= amount;
        }
        emit CategoryABalanceChanged(account, categoryAEligibleBalance[account]);
    }

    /// @notice One-shot TGE anchor. Bounded to guard against a ms-vs-seconds mistake.
    function setTgeTimestamp(uint256 timestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tgeTimestamp == 0, "TGE timestamp already set");
        require(timestamp > 0, "Gobi: zero timestamp");
        require(timestamp <= block.timestamp + 180 days, "Gobi: TGE timestamp too far in the future");
        uint256 lowerBound = block.timestamp > 30 days ? block.timestamp - 30 days : 0;
        require(timestamp >= lowerBound, "Gobi: TGE timestamp too far in the past");
        tgeTimestamp = timestamp;
        emit TgeTimestampSet(timestamp);
    }

    /// @notice Mint, capped at MAX_SUPPLY. Never credits eligible balance.
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Mint would exceed max supply");
        _mint(to, amount);
    }

    /// @notice Snapshot balances + supply. Called by the Adapter per epoch.
    function snapshot() public onlyRole(SNAPSHOT_ROLE) returns (uint256 newSnapshotId) {
        newSnapshotId = _snapshot();
        emit SnapshotTaken(newSnapshotId);
    }

    function getCurrentSnapshotId() public view returns (uint256) {
        return _getCurrentSnapshotId();
    }

    function balanceOfAt(address account, uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.balanceOfAt(account, snapshotId);
    }

    function totalSupplyAt(uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.totalSupplyAt(snapshotId);
    }

    /// @dev Hard lock: any wallet holding eligible balance cannot send
    /// anywhere while locked. Mint/burn exempt. Receiving is never blocked.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Snapshot) {
        if (from != address(0) && to != address(0) && categoryAEligibleBalance[from] > 0) {
            require(!lockupActive(), "SFA Section 276 Lockup: Category A transfers are locked");
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    /// @dev Credit: recipient gains eligible balance only if `from` is
    /// Sablier itself. Debit: sender's eligible balance is drawn down
    /// first on any outgoing transfer/burn, floored at zero.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        super._afterTokenTransfer(from, to, amount);

        if (from == sablierLockup && to != address(0)) {
            _adjustCategoryABalance(to, true, amount);
        }

        if (from != address(0)) {
            uint256 eligible = categoryAEligibleBalance[from];
            if (eligible > 0) {
                uint256 debit = amount > eligible ? eligible : amount;
                _adjustCategoryABalance(from, false, debit);
            }
        }
    }

    function _mint(address to, uint256 amount) internal override(ERC20) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20) {
        super._burn(account, amount);
    }
}
