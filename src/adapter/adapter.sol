// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "openzeppelin/utils/structs/EnumerableSet.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IGobiToken.sol";

/**
 * @title Adapter
 * @author Gobi Platform
 * @notice Epoch-based USDT yield distributor for GOBI holders, with the
 * JORC Corporate Yield Redirect: an optional per-epoch USDT subsidy paid
 * only to Category A (private-placement) holders, funded from Gobi
 * Platinum's corporate revenue share, without expanding token supply.
 *
 * @dev Correct-by-construction accounting: every epoch's numerators,
 * denominators, and eligibility are read from ONE token snapshot taken at
 * deposit, so claims can never sum to more than what was deposited.
 * - Base yield denominator:  totalSupplyAt(snap) − excluded balances.
 * - Subsidy denominator:     categoryATotalSupplyAt(snap) − excluded
 *                            Category A balances.
 * - Subsidy eligibility:     isCategoryAAt(claimant, snap) — the flag AS OF
 *                            the snapshot, so later taint or compliance
 *                            changes never alter a funded epoch.
 * Exclusion is frozen per epoch (epochExcluded) at deposit.
 * Recovery: sweepExcess can only remove balance above outstanding
 * liability; rescueToken cannot touch the yield asset. There is no
 * emergency drain.
 */
contract Adapter is IAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Role permitted to deposit yield epochs.
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice The USDT-like asset distributed as yield.
    IERC20 public immutable yieldAsset;

    /// @notice The GOBI token (snapshots, balances, Category A registry).
    IGobiToken public immutable gobiToken;

    /**
     * @notice One yield distribution round.
     * @param snapshotId               Token snapshot all math is read from.
     * @param totalUsdtAmount          Standard yield pool (all eligible holders).
     * @param corporateSubsidyAmount   JORC redirect pool (Category A only).
     * @param supplyAtSnapshot         Base denominator: eligible supply.
     * @param categoryASupplyAtSnapshot Subsidy denominator: eligible CatA supply.
     * @param ipfsHash                 Audit metadata CID.
     */
    struct Epoch {
        uint256 snapshotId;
        uint256 totalUsdtAmount;
        uint256 corporateSubsidyAmount;
        uint256 supplyAtSnapshot;
        uint256 categoryASupplyAtSnapshot;
        string ipfsHash;
    }

    /// @notice Epoch data by id.
    mapping(uint256 => Epoch) public epochs;

    /// @notice Next epoch id (== number of epochs so far).
    uint256 public currentEpochId;

    /// @dev Live excluded set (treasury, team, Sablier escrow, ...).
    EnumerableSet.AddressSet private _excluded;

    /// @notice Exclusion frozen per epoch at deposit time.
    mapping(uint256 => mapping(address => bool)) public epochExcluded;

    /// @notice Whether a wallet has claimed a given epoch.
    mapping(uint256 => mapping(address => bool)) public claimedWallet;

    /// @notice Lifetime USDT deposited (yield + subsidies).
    uint256 public totalDeposited;

    /// @notice Lifetime USDT claimed by holders.
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

    /**
     * @param defaultAdmin Multisig/trustee receiving DEFAULT_ADMIN_ROLE.
     * @param _yieldAsset  USDT-like reward token.
     * @param _gobiToken   GOBI token address.
     * @param _sablier     Sablier lockup address; auto-excluded so escrowed
     *                     (unvested) tokens earn no yield and no subsidy.
     */
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

    // ------------------------------------------------------------------
    // Exclusion management
    // ------------------------------------------------------------------

    /// @notice Excludes a wallet from all FUTURE epochs (yield and subsidy).
    /// @custom:access DEFAULT_ADMIN_ROLE
    function addExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Adapter: Target zero address");
        require(_excluded.add(account), "Adapter: Already excluded");
        emit ExclusionSet(account, true);
    }

    /// @notice Re-includes a wallet for FUTURE epochs; past epochs keep
    /// whatever was frozen at their deposit.
    /// @custom:access DEFAULT_ADMIN_ROLE
    function removeExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_excluded.remove(account), "Adapter: Not excluded");
        emit ExclusionSet(account, false);
    }

    /// @notice Whether a wallet is currently excluded (future epochs).
    function isExcluded(address account) external view returns (bool) {
        return _excluded.contains(account);
    }

    /// @notice Number of currently excluded wallets.
    function excludedCount() external view returns (uint256) {
        return _excluded.length();
    }

    /// @notice Excluded wallet at `index` (unordered).
    function excludedAt(uint256 index) external view returns (address) {
        return _excluded.at(index);
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    /**
     * @notice Deposits one epoch: `amount` of standard yield for all
     * eligible holders, plus an optional `subsidyAmount` (JORC Corporate
     * Yield Redirect) for Category A holders only.
     * @dev Takes a snapshot and derives BOTH denominators from it in the
     * same pass that freezes the excluded set, so numerators, denominators,
     * and eligibility all describe the same instant. Pulls
     * `amount + subsidyAmount` from the caller.
     * @param amount        Standard yield pool; must exceed zero.
     * @param subsidyAmount Corporate subsidy pool; zero for normal epochs.
     * @param ipfsHash      Audit metadata CID; must be non-empty.
     * @custom:access DEPOSITOR_ROLE
     * @custom:emits YieldDeposited
     */
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
            ipfsHash: ipfsHash
        });

        currentEpochId++;
        totalDeposited += amount + subsidyAmount;

        yieldAsset.safeTransferFrom(msg.sender, address(this), amount + subsidyAmount);

        emit YieldDeposited(epochId, amount, subsidyAmount, snapId, eligibleSupply, eligibleCatASupply, ipfsHash);
    }

    /**
     * @dev Derives both epoch denominators from snapshot `snapId` and
     * freezes the excluded set into `epochId` in the same pass.
     * @return eligibleSupply     totalSupplyAt − excluded balances.
     * @return eligibleCatASupply categoryATotalSupplyAt − excluded CatA balances.
     */
    function _deriveDenominators(uint256 snapId, uint256 epochId)
        private
        returns (uint256 eligibleSupply, uint256 eligibleCatASupply)
    {
        uint256 excludedSum = 0;
        uint256 excludedCatASum = 0;
        uint256 len = _excluded.length();
        for (uint256 i = 0; i < len; i++) {
            address acct = _excluded.at(i);
            uint256 bal = gobiToken.balanceOfAt(acct, snapId);
            excludedSum += bal;
            if (gobiToken.isCategoryAAt(acct, snapId)) {
                excludedCatASum += bal;
            }
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

    /**
     * @notice Claims yield (and, for snapshot-time Category A holders, the
     * corporate subsidy) across the given epochs.
     * @dev All reads are historical against each epoch's snapshot:
     * balances via balanceOfAt, subsidy eligibility via isCategoryAAt.
     * Live flag changes after a deposit never affect that epoch.
     * @param epochIds Epoch ids to claim; already-claimed and excluded
     * epochs are skipped, non-existent ids revert.
     * @custom:emits Claimed (one per epoch paid)
     */
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

            uint256 basePayout = (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;

            // JORC Corporate Yield Redirect: Category A holders (as of the
            // epoch snapshot) share the subsidy over the CatA denominator.
            uint256 subsidyPayout = 0;
            if (epoch.corporateSubsidyAmount > 0 && gobiToken.isCategoryAAt(msg.sender, epoch.snapshotId)) {
                subsidyPayout = (epoch.corporateSubsidyAmount * balance) / epoch.categoryASupplyAtSnapshot;
            }

            uint256 payout = basePayout + subsidyPayout;
            if (payout > 0) {
                claimedWallet[id][msg.sender] = true;
                totalPayout += payout;
                emit Claimed(id, msg.sender, basePayout, subsidyPayout);
            }
        }
        require(totalPayout > 0, "Adapter: No claimable yield available");
        totalClaimed += totalPayout;
        yieldAsset.safeTransfer(msg.sender, totalPayout);
    }

    // ------------------------------------------------------------------
    // Recovery (no drain vector)
    // ------------------------------------------------------------------

    /**
     * @notice Sweeps only the surplus above outstanding holder liability
     * (rounding dust accrues as liability; only stray direct transfers are
     * recoverable). Can never touch owed funds.
     * @param recipient Destination for the excess; must be non-zero.
     * @custom:access DEFAULT_ADMIN_ROLE
     * @custom:emits ExcessSwept
     */
    function sweepExcess(address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(recipient != address(0), "Adapter: Recipient zero address");
        uint256 outstanding = totalDeposited - totalClaimed;
        uint256 bal = yieldAsset.balanceOf(address(this));
        require(bal > outstanding, "Adapter: No excess to sweep");
        uint256 excess = bal - outstanding;
        emit ExcessSwept(recipient, excess);
        yieldAsset.safeTransfer(recipient, excess);
    }

    /**
     * @notice Rescues foreign tokens sent here by mistake. Explicitly
     * blocked from the yield asset (use {sweepExcess} for that).
     * @param token     Foreign token address; must not be the yield asset.
     * @param recipient Destination; must be non-zero.
     * @param amount    Amount to rescue; must exceed zero.
     * @custom:access DEFAULT_ADMIN_ROLE
     * @custom:emits TokenRescued
     */
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

    /// @notice Upper bound on USDT still owed to holders.
    function outstandingLiability() external view returns (uint256) {
        return totalDeposited - totalClaimed;
    }

    /**
     * @notice Claimable amount (base + any subsidy) for `account` in epoch
     * `epochId`; zero if non-existent, excluded, or already claimed.
     */
    function claimableWallet(uint256 epochId, address account) public view returns (uint256) {
        if (epochId >= currentEpochId || epochExcluded[epochId][account] || claimedWallet[epochId][account]) {
            return 0;
        }
        Epoch storage epoch = epochs[epochId];
        uint256 balance = gobiToken.balanceOfAt(account, epoch.snapshotId);
        if (balance == 0) return 0;
        uint256 payout = (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;
        if (epoch.corporateSubsidyAmount > 0 && gobiToken.isCategoryAAt(account, epoch.snapshotId)) {
            payout += (epoch.corporateSubsidyAmount * balance) / epoch.categoryASupplyAtSnapshot;
        }
        return payout;
    }
}
