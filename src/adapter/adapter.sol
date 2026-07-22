// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IGobiToken.sol";

/// @title Adapter
/// @notice Epoch-based USDT yield distributor for GOBI holders, plus the
/// JORC Corporate Yield Redirect: an optional per-epoch USDT subsidy paid
/// only on each holder's Category A-eligible (Sablier-sourced) balance.
/// @dev Base yield uses a holder's FULL balance. The subsidy uses ONLY the
/// Category A-eligible portion -- tokens from any other source are locked
/// by the token but never draw subsidy. All math is read from one token
/// snapshot taken at deposit, so claims can never exceed what's deposited.
/// Each epoch also has a claim window; once it passes, admin may reclaim
/// whatever's still unclaimed (e.g. dead wallets, lost keys, DEX pools
/// that can't call claimWallet) to a chosen address.
contract Adapter is IAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    IERC20 public immutable yieldAsset;
    IGobiToken public immutable gobiToken;

    /// @notice Floor on claimWindow so it can't be shortened to instantly
    /// expire epochs.
    uint256 public constant MIN_CLAIM_WINDOW = 30 days;

    /// @notice Window used to compute each epoch's claim deadline. Applied
    /// LIVE (epochStart + claimWindow), so changing it affects every
    /// epoch's effective deadline immediately, not just future deposits.
    uint256 public claimWindow = 365 days;

    /// @notice One yield distribution round.
    struct Epoch {
        uint256 snapshotId;
        uint256 totalUsdtAmount; // base yield pool, all eligible holders
        uint256 corporateSubsidyAmount; // JORC redirect, CatA-eligible balance only
        uint256 supplyAtSnapshot; // base denominator
        uint256 categoryASupplyAtSnapshot; // subsidy denominator
        uint256 deadline; // deposit timestamp; deadline = epochStart + claimWindow
        string ipfsHash;
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpochId;

    EnumerableSet.AddressSet private _excluded;
    mapping(uint256 => mapping(address => bool)) public epochExcluded;
    mapping(uint256 => mapping(address => bool)) public claimedWallet;

    /// @notice USDT actually paid out per epoch so far.
    mapping(uint256 => uint256) public epochClaimed;
    /// @notice Whether an epoch's unclaimed remainder has been reclaimed.
    mapping(uint256 => bool) public epochReclaimed;

    uint256 public totalDeposited;
    uint256 public totalClaimed;

    event ExclusionSet(address indexed account, bool excluded);
    event YieldDeposited(
        uint256 indexed epochId,
        uint256 amount,
        uint256 subsidyAmount,
        uint256 snapshotId,
        uint256 eligibleSupply,
        uint256 eligibleCategoryASupply,
        string ipfsHash
    );
    event Claimed(uint256 indexed epochId, address indexed claimant, uint256 basePayout, uint256 subsidyPayout);
    event ExcessSwept(address indexed recipient, uint256 amount);
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
    event ClaimWindowUpdated(uint256 newWindow);
    event ExpiredReclaimed(uint256 indexed epochId, address indexed recipient, uint256 amount);

    /// @param defaultAdmin Multisig/trustee receiving DEFAULT_ADMIN_ROLE.
    /// @param _yieldAsset  USDT-like reward token.
    /// @param _gobiToken   GOBI token address
    constructor(address defaultAdmin, address _yieldAsset, address _gobiToken) {
        require(defaultAdmin != address(0), "Adapter: Admin zero address");
        require(_yieldAsset != address(0), "Adapter: Yield asset zero address");
        require(_gobiToken != address(0), "Adapter: Gobi zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(DEPOSITOR_ROLE, defaultAdmin);

        yieldAsset = IERC20(_yieldAsset);
        gobiToken = IGobiToken(_gobiToken);
    }

    // ------------------------------------------------------------------
    // Exclusion management
    // ------------------------------------------------------------------

    /// @notice Excludes a wallet from all future epochs.
    /// @custom:access DEFAULT_ADMIN_ROLE
    function addExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Adapter: Target zero address");
        require(_excluded.add(account), "Adapter: Already excluded");
        emit ExclusionSet(account, true);
    }

    /// @notice Re-includes a wallet for future epochs.
    /// @custom:access DEFAULT_ADMIN_ROLE
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

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    /// @notice Deposits one epoch: `amount` base yield for all eligible
    /// holders, plus an optional `subsidyAmount` paid on Category
    /// A-eligible balance only.
    /// @custom:access DEPOSITOR_ROLE
    /// @custom:emits YieldDeposited
    function depositYield(uint256 amount, uint256 subsidyAmount, string calldata ipfsHash)
        external
        override
        onlyRole(DEPOSITOR_ROLE)
    {
        require(amount > 0, "Adapter: Deposit must exceed zero");
        require(bytes(ipfsHash).length > 0, "Adapter: IPFS hash cannot be empty");

        uint256 snapId = gobiToken.snapshot();
        uint256 epochId = currentEpochId;

        (uint256 eligibleSupply, uint256 eligibleCatASupply) = _deriveDenominators(snapId, epochId);
        if (subsidyAmount > 0) {
            require(eligibleCatASupply > 0, "Adapter: No eligible CategoryA supply");
        }

        epochs[epochId] = Epoch({
            snapshotId: snapId,
            totalUsdtAmount: amount,
            corporateSubsidyAmount: subsidyAmount,
            supplyAtSnapshot: eligibleSupply,
            categoryASupplyAtSnapshot: eligibleCatASupply,
            deadline: block.timestamp + claimWindow,
            ipfsHash: ipfsHash
        });

        currentEpochId++;
        totalDeposited += amount + subsidyAmount;

        yieldAsset.safeTransferFrom(msg.sender, address(this), amount + subsidyAmount);

        emit YieldDeposited(epochId, amount, subsidyAmount, snapId, eligibleSupply, eligibleCatASupply, ipfsHash);
    }

    /// @dev Derives both denominators from snapshot `snapId` and freezes
    /// the excluded set into `epochId`. Only the CatA-eligible portion of
    /// each excluded wallet's balance is removed from the subsidy
    /// denominator -- not its full balance.
    function _deriveDenominators(uint256 snapId, uint256 epochId)
        private
        returns (uint256 eligibleSupply, uint256 eligibleCatASupply)
    {
        uint256 excludedSum = 0;
        uint256 excludedCatASum = 0;
        uint256 len = _excluded.length();
        for (uint256 i = 0; i < len; i++) {
            address acct = _excluded.at(i);
            excludedSum += gobiToken.balanceOfAt(acct, snapId);
            excludedCatASum += gobiToken.categoryABalanceAt(acct, snapId);
            epochExcluded[epochId][acct] = true;
        }

        uint256 total = gobiToken.totalSupplyAt(snapId);
        require(total >= excludedSum, "Adapter: Excluded exceed total supply");
        eligibleSupply = total - excludedSum;
        require(eligibleSupply > 0, "Adapter: Eligible supply must exceed zero");

        uint256 catATotal = gobiToken.categoryATotalSupplyAt(snapId);
        require(catATotal >= excludedCatASum, "Adapter: Excluded CatA exceed CatA supply");
        eligibleCatASupply = catATotal - excludedCatASum;
    }

    // ------------------------------------------------------------------
    // Claim
    // ------------------------------------------------------------------

    /// @notice Claims base yield (full balance) plus subsidy (Category
    /// A-eligible balance only) across the given epochs.
    /// @custom:emits Claimed (one per epoch paid)
    function claimWallet(uint256[] calldata epochIds) external override nonReentrant {
        uint256 totalPayout = 0;
        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 id = epochIds[i];
            require(id < currentEpochId, "Adapter: Non-existent epoch");
            if (claimedWallet[id][msg.sender]) continue;
            if (epochExcluded[id][msg.sender]) continue;
            if (epochReclaimed[id]) continue;

            Epoch storage epoch = epochs[id];
            uint256 balance = gobiToken.balanceOfAt(msg.sender, epoch.snapshotId);
            if (balance == 0) continue;

            uint256 basePayout = (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;

            // Subsidy uses the CatA-eligible amount only -- tokens from any
            // other source earn base yield above but never the subsidy.
            uint256 subsidyPayout = 0;
            if (epoch.corporateSubsidyAmount > 0) {
                uint256 eligible = gobiToken.categoryABalanceAt(msg.sender, epoch.snapshotId);
                if (eligible > 0) {
                    subsidyPayout = (epoch.corporateSubsidyAmount * eligible) / epoch.categoryASupplyAtSnapshot;
                }
            }

            uint256 payout = basePayout + subsidyPayout;
            if (payout > 0) {
                claimedWallet[id][msg.sender] = true;
                epochClaimed[id] += payout;
                totalPayout += payout;
                emit Claimed(id, msg.sender, basePayout, subsidyPayout);
            }
        }
        require(totalPayout > 0, "Adapter: No claimable yield available");
        totalClaimed += totalPayout;
        yieldAsset.safeTransfer(msg.sender, totalPayout);
    }

    // ------------------------------------------------------------------
    // Expired-claim reclaim
    // ------------------------------------------------------------------

    /// @notice Updates the claim window. Applied live -- it changes the
    /// effective deadline of every epoch immediately, not just future ones.
    /// @custom:access DEFAULT_ADMIN_ROLE
    /// @custom:emits ClaimWindowUpdated
    function setClaimWindow(uint256 newWindow) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newWindow >= MIN_CLAIM_WINDOW, "Adapter: Claim window too short");
        claimWindow = newWindow;
        emit ClaimWindowUpdated(newWindow);
    }

    /// @notice Reclaims an expired epoch's unclaimed remainder to `recipient`.
    /// Soft deadline: claims stay valid right up until this is actually
    /// called, even past the nominal window.
    /// @custom:access DEFAULT_ADMIN_ROLE
    /// @custom:emits ExpiredReclaimed
    function reclaimExpired(uint256 epochId, address recipient)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(recipient != address(0), "Adapter: Recipient zero address");
        require(epochId < currentEpochId, "Adapter: Non-existent epoch");
        require(!epochReclaimed[epochId], "Adapter: Already reclaimed");

        Epoch storage epoch = epochs[epochId];
        require(block.timestamp >= epoch.deadline, "Adapter: Claim window still open");

        uint256 totalForEpoch = epoch.totalUsdtAmount + epoch.corporateSubsidyAmount;
        uint256 unclaimed = totalForEpoch - epochClaimed[epochId];
        require(unclaimed > 0, "Adapter: Nothing unclaimed for this epoch");

        epochReclaimed[epochId] = true;
        totalDeposited -= unclaimed;

        emit ExpiredReclaimed(epochId, recipient, unclaimed);
        yieldAsset.safeTransfer(recipient, unclaimed);
    }

    // ------------------------------------------------------------------
    // Recovery (no drain vector)
    // ------------------------------------------------------------------

    /// @notice Sweeps only the surplus above outstanding liability. Can
    /// never touch owed funds.
    /// @custom:access DEFAULT_ADMIN_ROLE
    /// @custom:emits ExcessSwept
    function sweepExcess(address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(recipient != address(0), "Adapter: Recipient zero address");
        uint256 outstanding = totalDeposited - totalClaimed;
        uint256 bal = yieldAsset.balanceOf(address(this));
        require(bal > outstanding, "Adapter: No excess to sweep");
        uint256 excess = bal - outstanding;
        emit ExcessSwept(recipient, excess);
        yieldAsset.safeTransfer(recipient, excess);
    }

    /// @notice Rescues foreign tokens sent here by mistake. Blocked from
    /// the yield asset (use {sweepExcess} for that).
    /// @custom:access DEFAULT_ADMIN_ROLE
    /// @custom:emits TokenRescued
    function rescueToken(address token, address recipient, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(token != address(yieldAsset), "Adapter: Use sweepExcess");
        require(recipient != address(0), "Adapter: Recipient zero address");
        require(amount > 0, "Adapter: Amount must exceed zero");
        emit TokenRescued(token, recipient, amount);
        IERC20(token).safeTransfer(recipient, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function outstandingLiability() external view returns (uint256) {
        return totalDeposited - totalClaimed;
    }

    /// @notice Current effective claim deadline for `epochId` (epochStart
    /// + the CURRENT claimWindow -- moves if the window is later changed).
    function epochDeadline(uint256 epochId) external view returns (uint256) {
        return epochs[epochId].deadline;
    }

    /// @notice Claimable amount (base + any subsidy) for `account` in
    /// epoch `epochId`; zero if non-existent, excluded, already claimed,
    /// or already reclaimed.
    function claimableWallet(uint256 epochId, address account) public view returns (uint256) {
        if (
            epochId >= currentEpochId || epochExcluded[epochId][account] || claimedWallet[epochId][account]
                || epochReclaimed[epochId]
        ) {
            return 0;
        }
        Epoch storage epoch = epochs[epochId];
        uint256 balance = gobiToken.balanceOfAt(account, epoch.snapshotId);
        if (balance == 0) return 0;
        uint256 payout = (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;
        if (epoch.corporateSubsidyAmount > 0) {
            uint256 eligible = gobiToken.categoryABalanceAt(account, epoch.snapshotId);
            if (eligible > 0) {
                payout += (epoch.corporateSubsidyAmount * eligible) / epoch.categoryASupplyAtSnapshot;
            }
        }
        return payout;
    }
}
