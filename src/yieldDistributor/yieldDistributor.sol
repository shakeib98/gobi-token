// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "./interfaces/IYieldDistributor.sol";
import "./interfaces/IGobiToken.sol";

/// @title Yield Distributor (GOBI Yield Distributor)
/// @notice Holds the quarterly USDT yield and distributes it pro-rata to GOBI
///         holders, based on each holder's historical balance at the epoch snapshot.
///
///         DENOMINATOR IS DERIVED, NEVER STORED.
///         For every epoch the yield-bearing supply is computed at the snapshot as:
///             totalSupplyAt(snap) - sum(balanceOfAt(excludedAddr, snap))
///         Because the per-wallet numerator and the denominator are read from the
///         same source of truth (the token's snapshot balances), the sum of all
///         claims for an epoch is always <= the deposited amount by construction
///         (equal, minus integer-division dust). There is no hand-maintained supply
///         figure to drift out of sync, so the double-count / insolvency class is
///         eliminated.
///
///         "Admission" of treasury tokens needs no special function: tokens simply
///         leave the (excluded) treasury via a normal transfer, and are picked up as
///         yield-bearing at the next snapshot automatically.
///
///         Locked vesting tokens are handled the same way: the Sablier/Hedgey escrow
///         address is an excluded address, so locked tokens do not earn; once an
///         investor withdraws to their own (non-excluded) wallet, that balance earns.
contract YieldDistributor is IYieldDistributor, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // --- Integrations (immutable) ---
    IERC20 public immutable yieldAsset; // USDT
    IGobiToken public immutable gobiToken;

    // --- Epochs ---
    struct Epoch {
        uint256 snapshotId; // token snapshot id taken at deposit
        uint256 totalAmount; // USDT deposited for this epoch
        uint256 supplyAtSnapshot; // DERIVED yield-bearing supply at the snapshot
        string ipfsHash; // mining/accounting audit CID
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpochId;

    // --- Exclusions ---
    // Current excluded set (treasury, Sablier/Hedgey escrow, etc.). Used to derive
    // the denominator at deposit time. Kept small and effectively static.
    address[] private _excludedList;
    mapping(address => bool) public isExcluded;

    // Per-epoch FROZEN exclusion membership. Captured at deposit so that toggling the
    // exclusion set later can never retroactively change who may claim a past epoch
    // (an address excluded at deposit was subtracted from that epoch's denominator and
    // must never claim it; an address included at deposit keeps its legitimate claim).
    mapping(uint256 => mapping(address => bool)) public epochExcluded;

    // --- Claims & accounting ---
    mapping(uint256 => mapping(address => bool)) public claimed;
    uint256 public totalDeposited; // lifetime USDT deposited
    uint256 public totalClaimed; // lifetime USDT claimed

    // --- Events ---
    event ExclusionAdded(address indexed account);
    event ExclusionRemoved(address indexed account);
    event YieldDeposited(
        uint256 indexed epochId,
        uint256 amount,
        uint256 snapshotId,
        uint256 derivedSupply,
        string ipfsHash
    );
    event Claimed(uint256 indexed epochId, address indexed claimant, uint256 payout);
    event ExcessSwept(address indexed recipient, uint256 amount);
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);

    /// @param defaultAdmin Multisig / timelock that administers the distributor.
    /// @param _yieldAsset  The yield asset (USDT).
    /// @param _gobiToken   The GOBI token (must implement snapshot/balanceOfAt/totalSupplyAt).
    /// @param _sablier     Vesting escrow address, seeded as excluded.
    constructor(
        address defaultAdmin,
        address _yieldAsset,
        address _gobiToken,
        address _sablier
    ) {
        require(defaultAdmin != address(0), "Adapter: Admin zero address");
        require(_yieldAsset != address(0), "Adapter: Yield asset zero address");
        require(_gobiToken != address(0), "Adapter: Gobi zero address");
        require(_sablier != address(0), "Adapter: Sablier zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(DEPOSITOR_ROLE, defaultAdmin);

        yieldAsset = IERC20(_yieldAsset);
        gobiToken = IGobiToken(_gobiToken);

        // Seed the vesting escrow as excluded. The treasury MUST also be excluded
        // (via addExclusion) before the first deposit — see addExclusion docs.
        _addExclusion(_sablier);
    }

    // ---------------------------------------------------------------------
    // Exclusion management
    // ---------------------------------------------------------------------

    /// @notice Add an address to the excluded set (treasury, vesting escrow, etc.).
    /// @dev    Excluded balances are subtracted from the derived denominator and the
    ///         address cannot claim epochs for which it was excluded. Configure the
    ///         full excluded set (at minimum: treasury + vesting escrow) BEFORE the
    ///         first deposit. Changes only affect epochs deposited afterwards.
    function addExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _addExclusion(account);
    }

    /// @notice Remove an address from the excluded set (affects future epochs only).
    function removeExclusion(address account) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isExcluded[account], "Adapter: Not excluded");
        isExcluded[account] = false;

        uint256 len = _excludedList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_excludedList[i] == account) {
                _excludedList[i] = _excludedList[len - 1];
                _excludedList.pop();
                break;
            }
        }
        emit ExclusionRemoved(account);
    }

    function _addExclusion(address account) internal {
        require(account != address(0), "Adapter: Exclude zero address");
        require(!isExcluded[account], "Adapter: Already excluded");
        isExcluded[account] = true;
        _excludedList.push(account);
        emit ExclusionAdded(account);
    }

    function getExcludedList() external view returns (address[] memory) {
        return _excludedList;
    }

    // ---------------------------------------------------------------------
    // Deposit (single path; denominator derived)
    // ---------------------------------------------------------------------

    /// @notice Open a new yield epoch: snapshot the token, derive the yield-bearing
    ///         supply, store the epoch, and pull `amount` USDT from the depositor.
    /// @dev    Single deposit path. Sablier handling is implicit: the escrow address is
    ///         excluded, so its locked balance is subtracted from the denominator. The
    ///         seasonal smoothing rule lives off-chain in how much USDT is funded per
    ///         deposit; this function distributes whatever is deposited.
    /// @param amount   USDT (in its own base units) to distribute for this epoch.
    /// @param ipfsHash Accounting/audit CID for the epoch.
    function depositYield(
        uint256 amount,
        string calldata ipfsHash
    ) external override onlyRole(DEPOSITOR_ROLE) nonReentrant {
        require(amount > 0, "Adapter: Deposit must exceed zero");
        require(bytes(ipfsHash).length > 0, "Adapter: IPFS hash cannot be empty");

        uint256 snapId = gobiToken.snapshot();
        uint256 epochId = currentEpochId++;

        // Derive the denominator AND freeze per-epoch exclusion in a single pass.
        uint256 excludedBalance = 0;
        address[] memory list = _excludedList;
        for (uint256 i = 0; i < list.length; i++) {
            excludedBalance += gobiToken.balanceOfAt(list[i], snapId);
            epochExcluded[epochId][list[i]] = true;
        }

        uint256 totalAtSnap = gobiToken.totalSupplyAt(snapId);
        require(totalAtSnap > excludedBalance, "Adapter: No yield-bearing supply");
        uint256 derivedSupply = totalAtSnap - excludedBalance;

        epochs[epochId] = Epoch({
            snapshotId: snapId,
            totalAmount: amount,
            supplyAtSnapshot: derivedSupply,
            ipfsHash: ipfsHash
        });

        totalDeposited += amount;

        emit YieldDeposited(epochId, amount, snapId, derivedSupply, ipfsHash);

        // Effects above, interaction last.
        yieldAsset.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

    /// @notice Claim yield for one or more epochs. A wallet's share of an epoch is
    ///         `epoch.totalAmount * balanceAtSnapshot / derivedSupply`.
    /// @dev    Safe against wallet-shuffling: a fresh wallet had a zero balance at the
    ///         snapshot, so it claims zero. Sums to <= the deposit by construction.
    function claim(uint256[] calldata epochIds) external override nonReentrant {
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 id = epochIds[i];
            require(id < currentEpochId, "Adapter: Non-existent epoch");

            if (claimed[id][msg.sender]) continue;
            if (epochExcluded[id][msg.sender]) continue; // excluded for this epoch

            Epoch storage epoch = epochs[id];
            uint256 balance = gobiToken.balanceOfAt(msg.sender, epoch.snapshotId);
            if (balance == 0) continue;

            uint256 payout = (epoch.totalAmount * balance) / epoch.supplyAtSnapshot;
            if (payout > 0) {
                claimed[id][msg.sender] = true;
                totalPayout += payout;
                emit Claimed(id, msg.sender, payout);
            }
        }

        require(totalPayout > 0, "Adapter: No claimable yield available");

        totalClaimed += totalPayout; // effects before interaction
        yieldAsset.safeTransfer(msg.sender, totalPayout);
    }

    /// @notice View the claimable amount for an account/epoch (0 if claimed/excluded).
    function claimable(address account, uint256 epochId) public view returns (uint256) {
        if (
            epochId >= currentEpochId ||
            claimed[epochId][account] ||
            epochExcluded[epochId][account]
        ) {
            return 0;
        }
        Epoch storage epoch = epochs[epochId];
        uint256 balance = gobiToken.balanceOfAt(account, epoch.snapshotId);
        return (epoch.totalAmount * balance) / epoch.supplyAtSnapshot;
    }

    // ---------------------------------------------------------------------
    // Recovery (cannot touch pending claims)
    // ---------------------------------------------------------------------

    /// @notice Outstanding USDT owed to holders that has not yet been claimed.
    function outstanding() public view returns (uint256) {
        return totalDeposited - totalClaimed;
    }

    /// @notice Yield asset held by the contract beyond outstanding liabilities
    ///         (rounding dust + any USDT sent in directly). Safe to remove.
    function excess() public view returns (uint256) {
        uint256 bal = yieldAsset.balanceOf(address(this));
        uint256 owed = outstanding();
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Sweep ONLY the excess yield asset (never pending claims).
    /// @dev    Replaces the old "drain everything" emergency function: this can never
    ///         reduce the balance below the outstanding liability, so holders' unclaimed
    ///         yield is always protected. Admin should still be a multisig/timelock.
    function sweepExcess(address recipient)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(recipient != address(0), "Adapter: Recipient zero address");
        uint256 amount = excess();
        require(amount > 0, "Adapter: No excess to sweep");
        emit ExcessSwept(recipient, amount);
        yieldAsset.safeTransfer(recipient, amount);
    }

    /// @notice Rescue a NON-yield token sent to the contract by mistake.
    /// @dev    Cannot be used on the yield asset (use sweepExcess for that), so it is
    ///         not a backdoor to holder funds.
    function rescueToken(
        address token,
        address recipient,
        uint256 amount
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(yieldAsset), "Adapter: Use sweepExcess for yield asset");
        require(recipient != address(0), "Adapter: Recipient zero address");
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRescued(token, recipient, amount);
    }
}
