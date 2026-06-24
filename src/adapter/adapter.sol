// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IGobiToken.sol";

contract Adapter is IAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Access Control Roles ---
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // --- Core Contract Integrations ---
    IERC20 public immutable yieldAsset;
    IGobiToken public immutable gobiToken;
    address public immutable sablierAddress; // Stored purely as an address to track locked token balance

    // --- System Calculation Metrics ---
    uint256 public yieldBearingSupply;

    // --- Epoch Struct & Storage ---
    struct Epoch {
        uint256 snapshotId;
        uint256 totalUsdtAmount;
        uint256 supplyAtSnapshot;
        string ipfsHash;
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpochId;

    // --- Storage Mappings ---
    mapping(address => bool) public isExcluded;
    mapping(uint256 => mapping(address => bool)) public claimedWallet;

    // --- Events ---
    event TreasuryAdmitted(
        address indexed holder,
        uint256 amount,
        uint256 newYieldBearingSupply
    );
    event ExclusionSet(address indexed account, bool excluded);
    event YieldDeposited(
        uint256 indexed epochId,
        uint256 amount,
        uint256 snapshotId,
        string ipfsHash
    );
    event Claimed(
        uint256 indexed epochId,
        address indexed claimant,
        uint256 payout
    );

    event EmergencyRewardsWithdrawn(
        address indexed recipient,
        uint256 amount
    );

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
        sablierAddress = _sablier;

        yieldBearingSupply = 270_000_000 * 10 ** 18;
    }

    // --- Core Functions ---

    /**
     * @notice Allows the admin to exclude specific addresses from the snapshot-based yield distribution path.
     *  @dev Excluded addresses will not receive yield through the claimWallet function, regardless of their Gobi token balance at the snapshot. This is intended for operational addresses like the treasury or team wallets that should not benefit from yield distributions. Exclusion status can be toggled on or off for any address, providing flexibility to adapt to changing circumstances or governance decisions.
     *  @param account The address to be excluded or included in the snapshot-based yield distribution.
     *  @param excluded A boolean value indicating whether the address should be excluded (true) or included (false) in the snapshot-based yield distribution.
     */
    function setExclusionStatus(
        address account,
        bool excluded
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Adapter: Target zero address");
        isExcluded[account] = excluded;
        emit ExclusionSet(account, excluded);
    }

    /**
     * @notice Allows the admin to admit treasury funds into the yield-bearing supply, which increases the base supply used for yield distribution calculations.
     *  @param holder The address representing the source of the treasury funds being admitted.
     *  @param amount The amount of USDT being admitted from the treasury into the yield-bearing supply.
     */
    function admitTreasury(
        address holder,
        uint256 amount
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(holder != address(0), "Adapter: Holder zero address");
        require(amount > 0, "Adapter: Amount must exceed zero");
        yieldBearingSupply += amount;
        emit TreasuryAdmitted(holder, amount, yieldBearingSupply);
    }

    /**
     * @notice DEPOSIT PATH 1: Designed for the initial/Month 10 yield distribution.
     * @dev Accepts 100% of the target seasonal yield budget, keeps only the portion
     * required to cover active circulating wallets.
     * @param amount The total 100% intended USDT budget for the entire global supply.
     * @param ipfsHash Mining audit CID.
     */
    function depositFirstYield(
        uint256 amount,
        string calldata ipfsHash
    ) external onlyRole(DEPOSITOR_ROLE) {
        require(amount > 0, "Adapter: Deposit must exceed zero");
        require(
            bytes(ipfsHash).length > 0,
            "Adapter: IPFS hash cannot be empty"
        );

        uint256 snapId = gobiToken.snapshot();
        uint256 epochId = currentEpochId;

        uint256 lockedInSablier = gobiToken.balanceOfAt(sablierAddress, snapId);
        require(
            yieldBearingSupply >= lockedInSablier,
            "Adapter: Locked tokens exceed base supply"
        );

        uint256 activeCirculatingSupply = yieldBearingSupply - lockedInSablier;
        require(
            activeCirculatingSupply > 0,
            "Adapter: Active supply must exceed zero"
        );

        uint256 keptAmount = (amount * activeCirculatingSupply) /
            yieldBearingSupply;
        require(keptAmount > 0, "Adapter: Kept amount must exceed zero");

        epochs[epochId] = Epoch({
            snapshotId: snapId,
            totalUsdtAmount: keptAmount,
            supplyAtSnapshot: activeCirculatingSupply,
            ipfsHash: ipfsHash
        });

        currentEpochId++;

        yieldAsset.safeTransferFrom(msg.sender, address(this), keptAmount);

        emit YieldDeposited(epochId, keptAmount, snapId, ipfsHash);
    }

    /**
     * @notice DEPOSIT PATH 2: Designed for regular subsequent yield distributions.
     * @dev Uses the baseline yieldBearingSupply directly as the denominator without evaluating Sablier.
     * @param amount The amount of USDT being deposited for the yield distribution.
     * @param ipfsHash The IPFS hash containing the metadata for this yield distribution epoch
     */
    function depositRegularYield(
        uint256 amount,
        string calldata ipfsHash
    ) external onlyRole(DEPOSITOR_ROLE) {
        require(amount > 0, "Adapter: Deposit must exceed zero");
        require(
            bytes(ipfsHash).length > 0,
            "Adapter: IPFS hash cannot be empty"
        );

        uint256 snapId = gobiToken.snapshot();
        uint256 epochId = currentEpochId;

        epochs[epochId] = Epoch({
            snapshotId: snapId,
            totalUsdtAmount: amount,
            supplyAtSnapshot: yieldBearingSupply,
            ipfsHash: ipfsHash
        });

        currentEpochId++;
        yieldAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit YieldDeposited(epochId, amount, snapId, ipfsHash);
    }

    /**
     * @notice Allows eligible wallets to claim their share of the yield distribution for specified epochs based on their Gobi token balance at the time of each epoch's snapshot.
     * @param epochIds An array of epoch IDs for which the caller wishes to claim yield.
     */
    function claimWallet(
        uint256[] calldata epochIds
    ) external override nonReentrant {
        require(
            !isExcluded[msg.sender],
            "Adapter: Wallet address is excluded from snapshot path"
        );

        uint256 totalPayout = 0;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 id = epochIds[i];
            require(id < currentEpochId, "Adapter: Non-existent epoch");

            if (claimedWallet[id][msg.sender]) {
                continue;
            }

            Epoch storage epoch = epochs[id];
            uint256 balance = gobiToken.balanceOfAt(
                msg.sender,
                epoch.snapshotId
            );

            if (balance == 0) {
                continue;
            }

            uint256 payout = (epoch.totalUsdtAmount * balance) /
                epoch.supplyAtSnapshot;

            if (payout > 0) {
                claimedWallet[id][msg.sender] = true;
                totalPayout += payout;
                emit Claimed(id, msg.sender, payout);
            }
        }

        require(totalPayout > 0, "Adapter: No claimable yield available");
        yieldAsset.safeTransfer(msg.sender, totalPayout);
    }

    /**
     * @notice EMERGENCY ONLY: Sweeps 100% of the contract's reward asset balance to a rescue wallet.
     * @dev SECURITY REQUIREMENT: To mitigate the extreme centralization/rug-pull risk flagged by security
     * scanners, the `DEFAULT_ADMIN_ROLE` MUST be assigned to a Multi-Sig wallet (e.g., Gnosis Safe 3-of-5)
     * or a governance timelock contract. It must never be held by a single EOA deployer key.
     * @dev Operational Impact: Draining the contract reduces the token balance to 0, which will cause all
     * subsequent user calls to `claimWallet()` to revert until funds are manually restored or migrated.
     * @param recipient The secure address (ideally an independent cold wallet or separate Multi-Sig)
     * designated to receive the swept yield assets.
     */
    function emergencyWithdrawRewards(
        address recipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(recipient != address(0), "Adapter: Recipient zero address");

        uint256 entireRewardBalance = yieldAsset.balanceOf(address(this));
        require(entireRewardBalance > 0, "Adapter: No reward assets present");

        // Perform state changes before external transfers (CEI Pattern)
        emit EmergencyRewardsWithdrawn(recipient, entireRewardBalance);

        // Escape hatch transfer
        yieldAsset.safeTransfer(recipient, entireRewardBalance);
    }

    /**
     * @notice View function to check the claimable yield for a specific wallet and epoch without executing a transaction.
     * @dev This function calculates the claimable yield based on the wallet's Gobi token balance at the time of the epoch's snapshot and the total yield allocated for that epoch.
     * @param epochId The ID of the epoch for which to check claimable yield.
     * @param account The address of the wallet for which to check claimable yield.
     * @return The amount of yield (in USDT) that the specified wallet can claim for the given epoch.
     */
    function claimableWallet(
        uint256 epochId,
        address account
    ) public view returns (uint256) {
        if (
            epochId >= currentEpochId ||
            isExcluded[account] ||
            claimedWallet[epochId][account]
        ) {
            return 0;
        }
        Epoch storage epoch = epochs[epochId];
        uint256 balance = gobiToken.balanceOfAt(account, epoch.snapshotId);
        return (epoch.totalUsdtAmount * balance) / epoch.supplyAtSnapshot;
    }
}
