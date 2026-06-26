// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IGobiToken.sol";

contract Adapter is IAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    IERC20 public immutable yieldAsset;
    IGobiToken public immutable gobiToken;

    struct Epoch {
        uint256 snapshotId;
        uint256 totalUsdtAmount;
        uint256 supplyAtSnapshot;
        string ipfsHash;
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpochId;

    EnumerableSet.AddressSet private _excluded;
    mapping(uint256 => mapping(address => bool)) public epochExcluded;
    mapping(uint256 => mapping(address => bool)) public claimedWallet;

    event ExclusionSet(address indexed account, bool excluded);
    event YieldDeposited(
        uint256 indexed epochId, uint256 amount, uint256 snapshotId, uint256 eligibleSupply, string ipfsHash
    );
    event Claimed(uint256 indexed epochId, address indexed claimant, uint256 payout);
    event EmergencyRewardsWithdrawn(address indexed recipient, uint256 amount);

    constructor(address defaultAdmin, address _yieldAsset, address _gobiToken, address _sablier) {
        require(defaultAdmin != address(0), "Adapter: Admin zero address");
        require(_yieldAsset != address(0), "Adapter: Yield asset zero address");
        require(_gobiToken != address(0), "Adapter: Gobi zero address");
        require(_sablier != address(0), "Adapter: Sablier zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(DEPOSITOR_ROLE, defaultAdmin);

        yieldAsset = IERC20(_yieldAsset);
        gobiToken = IGobiToken(_gobiToken);

        _excluded.add(_sablier);
        emit ExclusionSet(_sablier, true);
    }

    function addExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Adapter: Target zero address");
        require(_excluded.add(account), "Adapter: Already excluded");
        emit ExclusionSet(account, true);
    }

    function removeExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_excluded.remove(account), "Adapter: Not excluded");
        emit ExclusionSet(account, false);
    }

    function isExcluded(address account) external view returns (bool) {
        return _excluded.contains(account);
    }

    function excludedCount() external view returns (uint256) {
        return _excluded.length();
    }

    function excludedAt(uint256 index) external view returns (address) {
        return _excluded.at(index);
    }

    function depositYield(uint256 amount, string calldata ipfsHash) external override onlyRole(DEPOSITOR_ROLE) {
        require(amount > 0, "Adapter: Deposit must exceed zero");
        require(bytes(ipfsHash).length > 0, "Adapter: IPFS hash cannot be empty");

        uint256 snapId = gobiToken.snapshot();
        uint256 epochId = currentEpochId;

        uint256 total = gobiToken.totalSupplyAt(snapId);

        uint256 excludedSum = 0;
        uint256 len = _excluded.length();
        for (uint256 i = 0; i < len; i++) {
            address acct = _excluded.at(i);
            excludedSum += gobiToken.balanceOfAt(acct, snapId);
            epochExcluded[epochId][acct] = true;
        }

        require(total >= excludedSum, "Adapter: Excluded exceed total supply");
        uint256 eligibleSupply = total - excludedSum;
        require(eligibleSupply > 0, "Adapter: Eligible supply must exceed zero");

        epochs[epochId] =
            Epoch({snapshotId: snapId, totalUsdtAmount: amount, supplyAtSnapshot: eligibleSupply, ipfsHash: ipfsHash});

        currentEpochId++;
        yieldAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldDeposited(epochId, amount, snapId, eligibleSupply, ipfsHash);
    }

    function claimWallet(uint256[] calldata epochIds) external override nonReentrant {
        uint256 totalPayout = 0;
        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 id = epochIds[i];
            require(id < currentEpochId, "Adapter: Non-existent epoch");
            if (claimedWallet[id][msg.sender]) continue;
            if (epochExcluded[id][msg.sender]) continue;

            Epoch storage epoch = epochs[id];
            uint256 balance = gobiToken.balanceOfAt(msg.sender, epoch.snapshotId);
            if (balance == 0) continue;

            uint256 payout = (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;
            if (payout > 0) {
                claimedWallet[id][msg.sender] = true;
                totalPayout += payout;
                emit Claimed(id, msg.sender, payout);
            }
        }
        require(totalPayout > 0, "Adapter: No claimable yield available");
        yieldAsset.safeTransfer(msg.sender, totalPayout);
    }

    function emergencyWithdrawRewards(address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(recipient != address(0), "Adapter: Recipient zero address");
        uint256 entireRewardBalance = yieldAsset.balanceOf(address(this));
        require(entireRewardBalance > 0, "Adapter: No reward assets present");
        emit EmergencyRewardsWithdrawn(recipient, entireRewardBalance);
        yieldAsset.safeTransfer(recipient, entireRewardBalance);
    }

    function claimableWallet(uint256 epochId, address account) public view returns (uint256) {
        if (epochId >= currentEpochId || epochExcluded[epochId][account] || claimedWallet[epochId][account]) {
            return 0;
        }
        Epoch storage epoch = epochs[epochId];
        uint256 balance = gobiToken.balanceOfAt(account, epoch.snapshotId);
        return (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;
    }
}
