// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Snapshot.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import "openzeppelin/utils/Arrays.sol";

/**
 * @title GobiToken
 * @author Gobi Platform
 * @notice ERC-20 token backing the Gobi yield platform. Supports balance
 * snapshots for epoch-based yield distribution, a capped supply, and an
 * on-chain Transfer Restriction Registry enforcing the Singapore SFA
 * Section 276 lock-up on private-placement ("Category A") tokens.
 *
 * Compliance model (SFA §§274/275/276):
 * - Wallets flagged `isCategoryA` hold tokens acquired in the private
 *   placement. While the lock-up is active, they may transfer ONLY to
 *   wallets flagged `isAccredited` (verified Accredited Investors).
 * - All other wallets ("Category B" in the compliance memos) are
 *   unflagged and trade freely at all times.
 * - The lock-up runs for `LOCK_DURATION` from `tgeTimestamp` and is
 *   FAIL-CLOSED: until the TGE timestamp is set, Category A transfers
 *   are restricted. After expiry, restrictions lift automatically and
 *   Category A status stops propagating.
 *
 * Roles:
 * - DEFAULT_ADMIN_ROLE: multisig; manages roles and sets the TGE timestamp.
 * - MINTER_ROLE:        may mint up to MAX_SUPPLY.
 * - SNAPSHOT_ROLE:      may take snapshots (intended holder: the Adapter
 *                       contract, which snapshots at each yield deposit).
 * - COMPLIANCE_ROLE:    manages the Category A flags and the Accredited
 *                       Investor whitelist.
 */
contract GobiToken is ERC20, ERC20Snapshot, AccessControl, ERC20Burnable {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Maximum token supply (1.2 billion, 18 decimals).
    /// @dev Enforced in {mint} against the CURRENT totalSupply, so burned
    /// tokens free headroom for re-minting; this caps circulating supply
    /// at any moment, not cumulative lifetime issuance.
    uint256 public constant MAX_SUPPLY = 1_200_000_000e18;

    /// @notice Role permitted to mint new tokens, subject to {MAX_SUPPLY}.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role permitted to take balance snapshots.
    /// @dev Grant to the Adapter CONTRACT address (not the distributor EOA):
    /// the Adapter is `msg.sender` when it calls {snapshot} inside
    /// `depositYield`, so deposits revert if the role sits anywhere else.
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");

    /// @notice Role permitted to manage the SFA §276 restriction registry.
    /// @dev Intended holder: the compliance function of the MAS-licensed
    /// intermediary (or the appointed trustee). Even DEFAULT_ADMIN_ROLE
    /// cannot modify the registry without this role.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @notice Duration of the SFA §276 resale restriction after TGE.
    /// @dev 180 days approximates the statutory six-month window measured
    /// from a single global TGE anchor. Because every private acquisition
    /// (Jul–Sep 2026) precedes the Q4 TGE, this is strictly more
    /// conservative than the per-acquisition statutory clock.
    uint256 public constant LOCK_DURATION = 180 days;

    // ------------------------------------------------------------------
    // SFA §276 Transfer Restriction Registry — state
    // ------------------------------------------------------------------

    /**
     * @notice Whether a wallet's tokens are restricted (Category A).
     * @dev Marks SENDERS. True = the wallet holds private-placement tokens
     * and, while {lockupActive}, may transfer only to accredited wallets.
     * Set by compliance at distribution and propagated automatically to
     * recipients during the lock-up (see {_afterTokenTransfer}).
     * The absence of the flag is what the compliance memos call
     * "Category B": unrestricted, freely tradeable.
     */
    mapping(address => bool) public isCategoryA;

    /**
     * @notice Whether a wallet is a verified Accredited Investor.
     * @dev Marks RECIPIENTS. True = compliance has verified the wallet's
     * owner qualifies as an Accredited Investor under the SFA, making the
     * wallet a lawful destination for Category A tokens during the
     * lock-up. Independent of {isCategoryA}: a wallet may be either flag,
     * both, or neither.
     */
    mapping(address => bool) public isAccredited;

    /**
     * @notice Sum of balances currently held by Category A wallets.
     * @dev Maintained incrementally at every point Category A membership or
     * a Category A wallet's balance changes, and checkpointed against the
     * same snapshot ids as ERC20Snapshot so the yield Adapter can read a
     * historically consistent subsidy denominator via
     * {categoryATotalSupplyAt}.
     */
    uint256 public categoryATotalSupply;

    /// @dev Checkpoint storage mirroring ERC20Snapshot's internal scheme.
    struct CatASnapshots {
        uint256[] ids;
        uint256[] values;
    }

    /// @dev Per-wallet history of the Category A flag (1 = flagged, 0 = not).
    mapping(address => CatASnapshots) private _categoryAFlagSnapshots;

    /// @dev History of {categoryATotalSupply}.
    CatASnapshots private _categoryASupplySnapshots;

    /**
     * @notice Timestamp of the public Token Generation Event; anchors the
     * lock-up clock.
     * @dev Zero means "not yet set", which {lockupActive} treats as
     * lock-up ACTIVE (fail-closed). One-shot: see {setTgeTimestamp}.
     */
    uint256 public tgeTimestamp;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice Emitted when a balance snapshot is taken.
    /// @param snapshotId The id of the newly created snapshot.
    event SnapshotTaken(uint256 indexed snapshotId);

    /// @notice Emitted when a wallet's Category A flag changes, whether by
    /// compliance action or automatic propagation during the lock-up.
    /// @param account The wallet whose flag changed.
    /// @param status  The new flag value.
    event CategoryASet(address indexed account, bool status);

    /// @notice Emitted when a wallet's Accredited Investor status changes.
    /// @param account The wallet whose status changed.
    /// @param status  The new status.
    event AccreditationSet(address indexed account, bool status);

    /// @notice Emitted once, when the TGE timestamp is anchored.
    /// @param timestamp The TGE timestamp.
    event TgeTimestampSet(uint256 timestamp);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /**
     * @notice Deploys the token and mints the initial supply.
     * @dev Grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to the multisig and
     * mints 400,000,000 GOBI to it. COMPLIANCE_ROLE and SNAPSHOT_ROLE are
     * NOT granted here; the admin must assign them post-deploy (compliance
     * to the licensed intermediary/trustee, snapshot to the Adapter).
     * @param multisig Address receiving admin, minter, and initial supply.
     * Must not be the zero address.
     */
    constructor(address multisig) ERC20("Gobi Token", "GOBI") {
        require(multisig != address(0), "Multisig address cannot be zero");
        _grantRole(DEFAULT_ADMIN_ROLE, multisig);
        _grantRole(MINTER_ROLE, multisig);
        _mint(multisig, 400_000_000e18);
    }

    // ------------------------------------------------------------------
    // Lock-up state
    // ------------------------------------------------------------------

    /**
     * @notice Returns true while Category A transfers are restricted.
     * @dev Fail-closed by design: if {tgeTimestamp} has not been set, the
     * lock-up is treated as ACTIVE, so private tokens can never become
     * freely transferable merely because an admin step was missed.
     * Becomes false automatically once
     * `block.timestamp >= tgeTimestamp + LOCK_DURATION`; no admin action
     * is needed to lift the restriction.
     * @return active True if the lock-up is in force.
     */
    function lockupActive() public view returns (bool active) {
        return tgeTimestamp == 0 || block.timestamp < tgeTimestamp + LOCK_DURATION;
    }

    // ------------------------------------------------------------------
    // Category A snapshot views (used by the yield Adapter)
    // ------------------------------------------------------------------

    /**
     * @notice Whether `account` was Category A at snapshot `snapshotId`.
     * @dev Historically frozen: later flag changes (compliance action or
     * taint) never alter the answer for past snapshots. This is what lets
     * the Adapter freeze subsidy eligibility per epoch.
     * @param account    The wallet to query.
     * @param snapshotId The snapshot id; must reference an existing snapshot.
     * @return True if the wallet was Category A at that snapshot.
     */
    function isCategoryAAt(address account, uint256 snapshotId) public view returns (bool) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _categoryAFlagSnapshots[account]);
        return snapshotted ? value == 1 : isCategoryA[account];
    }

    /**
     * @notice Total Category A-held supply at snapshot `snapshotId`.
     * @dev Aligned with {balanceOfAt}: for any snapshot, the sum of
     * balanceOfAt over wallets with isCategoryAAt == true equals this
     * value. The Adapter uses it as the subsidy denominator.
     * @param snapshotId The snapshot id; must reference an existing snapshot.
     * @return The Category A supply at that snapshot.
     */
    function categoryATotalSupplyAt(uint256 snapshotId) public view returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _categoryASupplySnapshots);
        return snapshotted ? value : categoryATotalSupply;
    }

    /// @dev Lookup mirroring ERC20Snapshot's _valueAt.
    function _valueAt(uint256 snapshotId, CatASnapshots storage snaps) private view returns (bool, uint256) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");
        uint256 index = Arrays.findUpperBound(snaps.ids, snapshotId);
        if (index == snaps.ids.length) {
            return (false, 0);
        }
        return (true, snaps.values[index]);
    }

    /// @dev Records `currentValue` at the current snapshot id if this is the
    /// first change since that snapshot (write-before-modify, like OZ).
    function _updateSnapshot(CatASnapshots storage snaps, uint256 currentValue) private {
        uint256 currentId = _getCurrentSnapshotId();
        uint256 last = snaps.ids.length == 0 ? 0 : snaps.ids[snaps.ids.length - 1];
        if (last < currentId) {
            snaps.ids.push(currentId);
            snaps.values.push(currentValue);
        }
    }

    /// @dev Flips `account`'s Category A flag with checkpointing and keeps
    /// {categoryATotalSupply} consistent with the wallet's current balance.
    function _setCategoryAFlag(address account, bool status) private {
        if (isCategoryA[account] == status) {
            return; // no-op; nothing to checkpoint
        }
        _updateSnapshot(_categoryAFlagSnapshots[account], isCategoryA[account] ? 1 : 0);
        _updateSnapshot(_categoryASupplySnapshots, categoryATotalSupply);
        isCategoryA[account] = status;
        uint256 bal = balanceOf(account);
        if (status) {
            categoryATotalSupply += bal;
        } else {
            categoryATotalSupply -= bal;
        }
        emit CategoryASet(account, status);
    }

    /// @dev Adjusts {categoryATotalSupply} by a signed delta with checkpointing.
    function _adjustCategoryASupply(bool increase, uint256 amount) private {
        if (amount == 0) return;
        _updateSnapshot(_categoryASupplySnapshots, categoryATotalSupply);
        if (increase) {
            categoryATotalSupply += amount;
        } else {
            categoryATotalSupply -= amount;
        }
    }

    // ------------------------------------------------------------------
    // Compliance functions
    // ------------------------------------------------------------------

    /**
     * @notice Flags or unflags a wallet as Category A (restricted).
     * @dev Unflagging a wallet mid-lock-up releases its tokens to the open
     * market; compliance must ensure this is lawful before doing so.
     * @param account The wallet to update. Must not be the zero address.
     * @param status  True to restrict, false to release.
     * @custom:access COMPLIANCE_ROLE
     * @custom:emits CategoryASet
     */
    function setCategoryA(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
        require(account != address(0), "Gobi: zero address");
        _setCategoryAFlag(account, status);
    }

    /**
     * @notice Sets or revokes a wallet's Accredited Investor status.
     * @dev Revocation takes effect immediately: pending transfers to the
     * wallet from Category A holders will revert from the next block.
     * @param account The wallet to update. Must not be the zero address.
     * @param status  True to whitelist, false to revoke.
     * @custom:access COMPLIANCE_ROLE
     * @custom:emits AccreditationSet
     */
    function setAccreditationStatus(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
        require(account != address(0), "Gobi: zero address");
        isAccredited[account] = status;
        emit AccreditationSet(account, status);
    }

    /**
     * @notice Batch variant of {setAccreditationStatus} for onboarding the
     * verified investor list efficiently.
     * @param accounts Wallets to update; none may be the zero address.
     * @param status   Status applied to every wallet in the batch.
     * @custom:access COMPLIANCE_ROLE
     * @custom:emits AccreditationSet (one per wallet)
     */
    function setAccreditationStatusBatch(address[] calldata accounts, bool status) external onlyRole(COMPLIANCE_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Gobi: zero address");
            isAccredited[accounts[i]] = status;
            emit AccreditationSet(accounts[i], status);
        }
    }

    /**
     * @notice Batch variant of {setCategoryA} for flagging the private
     * distribution addresses efficiently.
     * @param accounts Wallets to update; none may be the zero address.
     * @param status   Flag applied to every wallet in the batch.
     * @custom:access COMPLIANCE_ROLE
     * @custom:emits CategoryASet (one per wallet)
     */
    function setCategoryABatch(address[] calldata accounts, bool status) external onlyRole(COMPLIANCE_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Gobi: zero address");
            _setCategoryAFlag(accounts[i], status);
        }
    }

    /**
     * @notice Anchors the lock-up clock to the public TGE. One-shot.
     * @dev Cannot be changed once set — a mistaken value cannot be
     * corrected and would require redeployment; set with care. Until this
     * is called, {lockupActive} returns true (fail-closed).
     * @param timestamp The TGE timestamp; must be non-zero.
     * @custom:access DEFAULT_ADMIN_ROLE
     * @custom:emits TgeTimestampSet
     */
    function setTgeTimestamp(uint256 timestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tgeTimestamp == 0, "TGE timestamp already set");
        require(timestamp > 0, "Gobi: zero timestamp");
        require(timestamp <= block.timestamp + 180 days, "Gobi: TGE timestamp too far in the future");
        uint256 lowerBound = block.timestamp > 30 days ? block.timestamp - 30 days : 0;
        require(timestamp >= lowerBound, "Gobi: TGE timestamp too far in the past");
        tgeTimestamp = timestamp;
        emit TgeTimestampSet(timestamp);
    }

    // ------------------------------------------------------------------
    // Mint / snapshot
    // ------------------------------------------------------------------

    /**
     * @notice Mints new tokens, subject to {MAX_SUPPLY}.
     * @dev Minting is exempt from the transfer restriction (from ==
     * address(0)), so tokens can be minted directly to Category A wallets.
     * @param to     Recipient address.
     * @param amount Amount to mint.
     * @custom:access MINTER_ROLE
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Mint would exceed max supply");
        _mint(to, amount);
    }

    /**
     * @notice Takes a snapshot of all balances and the total supply.
     * @dev Called by the Adapter at each yield deposit; the resulting id is
     * the basis for that epoch's pro-rata distribution.
     * @return newSnapshotId The id of the newly created snapshot.
     * @custom:access SNAPSHOT_ROLE (the Adapter contract)
     * @custom:emits SnapshotTaken
     */
    function snapshot() public onlyRole(SNAPSHOT_ROLE) returns (uint256 newSnapshotId) {
        newSnapshotId = _snapshot();
        emit SnapshotTaken(newSnapshotId);
    }

    /// @notice Returns the id of the most recent snapshot (0 if none).
    /// @return The current snapshot id.
    function getCurrentSnapshotId() public view returns (uint256) {
        return _getCurrentSnapshotId();
    }

    /**
     * @notice Returns `account`'s balance at snapshot `snapshotId`.
     * @param account    The account to query.
     * @param snapshotId The snapshot id; must reference an existing snapshot.
     * @return The balance at that snapshot.
     */
    function balanceOfAt(address account, uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.balanceOfAt(account, snapshotId);
    }

    /**
     * @notice Returns the total supply at snapshot `snapshotId`.
     * @param snapshotId The snapshot id; must reference an existing snapshot.
     * @return The total supply at that snapshot.
     */
    function totalSupplyAt(uint256 snapshotId) public view override(ERC20Snapshot) returns (uint256) {
        return super.totalSupplyAt(snapshotId);
    }

    // ------------------------------------------------------------------
    // Transfer hooks — SFA §276 enforcement (OpenZeppelin 4.9 pattern)
    // ------------------------------------------------------------------

    /**
     * @dev Enforces the SFA §276 resale restriction and forwards to the
     * parents (including ERC20Snapshot's balance checkpointing).
     *
     * Rule: while {lockupActive}, a Category A sender may transfer only to
     * a wallet on the {isAccredited} whitelist; anything else reverts.
     * Minting (`from == address(0)`) and burning (`to == address(0)`) are
     * exempt, and RECEIVING into a Category A wallet is never blocked —
     * the restriction binds senders, not recipients.
     *
     * @param from   Token sender (address(0) on mint).
     * @param to     Token recipient (address(0) on burn).
     * @param amount Amount transferred.
     * @inheritdoc ERC20
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Snapshot) {
        if (from != address(0) && to != address(0)) {
            if (isCategoryA[from] && lockupActive()) {
                require(isAccredited[to], "SFA Section 276 Lockup: Recipient must be an Accredited Investor");
            }
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Propagates the Category A flag to recipients ("taint"), gated on
     * the lock-up window.
     *
     * While {lockupActive}, tokens leaving a Category A wallet mark the
     * recipient as Category A, so restricted tokens cannot be laundered to
     * the public market through an accredited intermediary — the flag (and
     * therefore the restriction) follows the tokens through any chain of
     * lawful transfers. Once the lock-up expires the propagation stops,
     * preventing indefinite taint spread and, downstream, leakage of any
     * Category-A-only yield subsidy to the public market.
     *
     * Note: flags are per-wallet on a fungible token, so receiving any
     * amount of Category A tokens restricts the recipient's ENTIRE
     * balance for the remainder of the lock-up.
     *
     * @param from   Token sender (address(0) on mint).
     * @param to     Token recipient (address(0) on burn).
     * @param amount Amount transferred.
     * @custom:emits CategoryASet when a new wallet is tainted.
     * @inheritdoc ERC20
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        super._afterTokenTransfer(from, to, amount);

        // Flag states BEFORE any taint applied by this hook.
        bool fromCatA = from != address(0) && isCategoryA[from];
        bool toCatA = to != address(0) && isCategoryA[to];

        // Keep categoryATotalSupply aligned with balance movement across
        // the Category A boundary (covers transfers, mint, burn). A
        // transfer where BOTH sides are already Category A moves balance
        // entirely within the flagged set, so the subtract and add would
        // cancel to a net-zero change.
        if (fromCatA != toCatA) {
            if (fromCatA) {
                _adjustCategoryASupply(false, amount); // CatA balance left
            } else {
                _adjustCategoryASupply(true, amount); // CatA balance arrived
            }
        }

        // Taint: recipient inherits Category A during the lock-up. The new
        // wallet's ENTIRE post-transfer balance joins the CatA supply
        // (handled inside _setCategoryAFlag via balanceOf).
        if (from != address(0) && to != address(0) && fromCatA && !toCatA && lockupActive()) {
            _setCategoryAFlag(to, true);
        }
    }

    /// @dev Override required by Solidity due to multiple inheritance.
    function _mint(address to, uint256 amount) internal override(ERC20) {
        super._mint(to, amount);
    }

    /// @dev Override required by Solidity due to multiple inheritance.
    function _burn(address account, uint256 amount) internal override(ERC20) {
        super._burn(account, amount);
    }
}
