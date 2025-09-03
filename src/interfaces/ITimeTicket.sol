// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITimeTicket Interface
/// @notice Interface for the TimeTicket contract - a 15-minute round-based FOMO game
/// @dev Comprehensive interface including all events, structures, and function declarations
interface ITimeTicket {
    // ============ EVENTS ============

    /// @notice Emitted when a new round starts
    /// @param roundId The unique identifier for the round
    /// @param startTime Unix timestamp when the round started
    /// @param endTime Initial end time for the round (extends with purchases)
    /// @param startingTicketPrice Initial price per ticket for this round
    /// @param carryPool Amount carried over from previous round
    event RoundStarted(
        uint256 indexed roundId,
        uint64 startTime,
        uint64 endTime,
        uint256 startingTicketPrice,
        uint256 carryPool
    );

    /// @notice Emitted when a user purchases tickets
    /// @param roundId The round in which tickets were purchased
    /// @param buyer Address of the ticket buyer
    /// @param quantity Number of tickets purchased
    /// @param ticketPrice Price per ticket at time of purchase
    /// @param newEndTime Updated end time after round extension
    event TicketPurchased(
        uint256 indexed roundId,
        address indexed buyer,
        uint256 quantity,
        uint256 ticketPrice,
        uint64 newEndTime
    );

    /// @notice Emitted when a user claims a free ticket
    /// @param roundId The round for which the free ticket was claimed
    /// @param user Address of the user claiming the free ticket
    event FreeTicketClaimed(uint256 indexed roundId, address indexed user);

    /// @notice Emitted when the team vault provides funding to a round
    /// @param roundId The round that received funding
    /// @param desiredAmount The amount that was supposed to be funded
    /// @param injectedAmount The actual amount funded (may be less if vault insufficient)
    /// @param ratioBps The funding ratio in basis points (determined by VRF)
    event VaultFunded(
        uint256 indexed roundId,
        uint256 desiredAmount,
        uint256 injectedAmount,
        uint16 ratioBps
    );

    /// @notice Emitted when a round is settled
    /// @param roundId The round that was settled
    /// @param winner Address of the round winner (last buyer)
    /// @param totalPool Total prize pool for the round
    /// @param winnerAmount Amount allocated to the winner
    /// @param dividendAmount Total amount allocated for participant dividends
    /// @param airdropAmount Total amount allocated for airdrop winners
    /// @param teamAmount Amount sent to the team vault
    /// @param carryAmount Amount carried over to the next round
    event RoundSettled(
        uint256 indexed roundId,
        address indexed winner,
        uint256 totalPool,
        uint256 winnerAmount,
        uint256 airdropAmount,
        uint256 dividendAmount,
        uint256 teamAmount,
        uint256 carryAmount
    );

    /// @notice Emitted when a user claims rewards
    /// @param roundId The round from which rewards were claimed
    /// @param grossPayout Total gross amount before fees
    /// @param rewardTypes Array of reward types claimed
    /// @param user Address of the user claiming rewards
    event Claimed(
        uint256 indexed roundId,
        uint256 grossPayout,
        RewardType[] rewardTypes,
        address indexed user
    );

    /// @notice Emitted when contract configuration is updated
    /// @param key String identifier of the configuration parameter changed
    event ConfigUpdated(string key);

    /// @notice Emitted when expired unclaimed rewards are swept to the vault
    /// @param roundId The round whose expired rewards were swept
    /// @param amount Amount swept to the vault
    event ExpiredSwept(uint256 indexed roundId, uint256 amount);

    // ============ ENUMS ============

    /// @notice Types of rewards that can be claimed
    /// @dev Rewards are EXCLUSIVE - users can only claim ONE type per round:
    ///      - Winner: Final winner gets 48% of net pool
    ///      - Airdrop: Random winners get 10% split (excludes final winner)
    ///      - Dividend: All other participants get 20% split (excludes winner & airdrop winners)
    enum RewardType {
        Winner, // Winner reward (48% of net pool) - EXCLUSIVE
        Airdrop, // Airdrop reward (10% split) - EXCLUSIVE to non-winners
        Dividend // Participant dividend (20% split) - EXCLUSIVE to non-winners/non-airdrop
    }

    // ============ STRUCTS ============

    /// @notice Metadata for each round
    struct RoundMeta {
        uint64 startTime; // When the round started
        uint64 endTime; // When the round will/did end
        uint256 pool; // Total prize pool
        uint256 totalTickets; // Total tickets purchased
        address lastBuyer; // Address of last ticket buyer (winner)
        bool settled; // Whether the round has been settled
        uint16 fundingRatioBps; // VRF-determined funding ratio in basis points
        address winner; // Winner address (set during settlement)
        uint256 unclaimed; // Total gross claimable amount remaining
    }

    // ============ CONSTANTS ============

    /// @notice Protocol fee in parts per million (0.001%)
    function FEE_PPM() external view returns (uint256);

    /// @notice Base round duration (60 minutes)
    function BASE_ROUND_DURATION() external view returns (uint256);

    // ============ STATE VARIABLES ============

    // Core game state
    function currentRoundId() external view returns (uint256);
    function extensionPerTicket() external view returns (uint256);
    function ticketPrice() external view returns (uint256);
    function startingTicketPrice() external view returns (uint256);
    function priceIncrementPerPurchase() external view returns (uint256);
    function vault() external view returns (address);
    function feeRecipient() external view returns (address);
    function airdropWinnersCount() external view returns (uint32);

    // VRF configuration
    function defaultCallbackGas() external view returns (uint256);
    function defaultMaxAllowedGasPrice() external view returns (uint256);

    // Distribution configuration (in basis points)
    function fundingRatioMinBps() external view returns (uint16);
    function fundingRatioRangeBps() external view returns (uint16);
    function winnerBps() external view returns (uint16);
    function dividendBps() external view returns (uint16);
    function airdropBps() external view returns (uint16);
    function teamBps() external view returns (uint16);
    function carryBps() external view returns (uint16);

    // Claim expiry configuration
    function claimExpiryRounds() external view returns (uint256);

    // ============ MAPPINGS ============

    // Round data
    function rounds(
        uint256 roundId
    )
        external
        view
        returns (
            uint64 startTime,
            uint64 endTime,
            uint256 pool,
            uint256 totalTickets,
            address lastBuyer,
            bool settled,
            uint16 fundingRatioBps,
            address winner,
            uint256 unclaimed
        );
    function roundRandomness(uint256 roundId) external view returns (uint256);
    function requestToRound(uint256 requestId) external view returns (uint256);
    function roundToRequest(uint256 roundId) external view returns (uint256);

    // User participation
    function ticketsOf(
        uint256 roundId,
        address user
    ) external view returns (uint256);
    function userRounds(
        address user,
        uint256 index
    ) external view returns (uint256);

    // Reward calculations
    function winnerShareOfRound(
        uint256 roundId
    ) external view returns (uint256);
    function dividendPerParticipant(
        uint256 roundId
    ) external view returns (uint256);
    function airdropWinners(
        uint256 roundId,
        uint256 index
    ) external view returns (address);
    function isAirdropWinner(
        uint256 roundId,
        address user
    ) external view returns (bool);
    function airdropPerWinner(uint256 roundId) external view returns (uint256);

    // Claim tracking
    function claimedWinner(uint256 roundId) external view returns (bool);
    function claimedDividend(
        uint256 roundId,
        address user
    ) external view returns (bool);
    function claimedAirdrop(
        uint256 roundId,
        address user
    ) external view returns (bool);
    function totalClaimed(address user) external view returns (uint256);

    // Expiry tracking
    function sweptExpired(uint256 roundId) external view returns (bool);

    // ============ CORE FUNCTIONS ============

    /// @notice Initialize the contract (upgradeable pattern)
    /// @param _ticketPrice Starting ticket price in wei
    /// @param _vault Address of the team vault contract
    /// @param _goatVrf Address of the VRF coordinator contract
    function initialize(
        uint256 _ticketPrice,
        address _vault,
        address _goatVrf
    ) external;

    /// @notice Purchase tickets for the current round
    /// @param quantity Number of tickets to purchase
    /// @param maxTotalCost Maximum acceptable total cost (slippage protection)
    /// @param deadline Transaction deadline timestamp
    function buy(
        uint256 quantity,
        uint256 maxTotalCost,
        uint256 deadline
    ) external payable;

    /// @notice Settle the current round and start the next one
    function settle() external;

    /// @notice Claim rewards from a specific round
    /// @param roundId The round to claim rewards from
    /// @param rewardTypes Array of reward types to claim
    function claim(uint256 roundId, RewardType[] calldata rewardTypes) external;

    /// @notice Sweep expired unclaimed rewards to the vault
    /// @param roundId The round to sweep expired rewards from
    function sweepExpired(uint256 roundId) external;

    // ============ ADMIN FUNCTIONS ============

    /// @notice Set the team vault address
    /// @param newVault New vault contract address
    function setVault(address newVault) external;

    /// @notice Set the starting ticket price for new rounds
    /// @param newStartingPrice New starting price in wei
    function setStartingTicketPrice(uint256 newStartingPrice) external;

    /// @notice Set the price increment per purchase
    /// @param newIncrement New increment amount in wei
    function setPriceIncrementPerPurchase(uint256 newIncrement) external;

    /// @notice Set the number of airdrop winners per round
    /// @param newCount New number of airdrop winners
    function setAirdropWinnersCount(uint32 newCount) external;

    /// @notice Set the time extension per ticket purchase
    /// @param newExtension New extension duration in seconds
    function setExtensionPerTicket(uint256 newExtension) external;

    /// @notice Set the protocol fee recipient
    /// @param newRecipient New fee recipient address
    function setFeeRecipient(address newRecipient) external;

    /// @notice Set the VRF coordinator address
    /// @param newVrf New VRF coordinator address
    function setGoatVrf(address newVrf) external;

    /// @notice Set VRF parameters
    /// @param callbackGas Gas limit for VRF callback
    /// @param maxAllowedGasPrice Maximum gas price for VRF
    function setDefaultVrfParams(
        uint256 callbackGas,
        uint256 maxAllowedGasPrice
    ) external;

    /// @notice Set claim expiry duration
    /// @param newExpiry Number of rounds after which claims expire
    function setClaimExpiryRounds(uint256 newExpiry) external;

    /// @notice Set distribution parameters
    /// @param _fundingRatioMinBps Minimum funding ratio in basis points
    /// @param _fundingRatioRangeBps Funding ratio range in basis points
    /// @param _winnerBps Winner share in basis points
    /// @param _dividendBps Dividend share in basis points
    /// @param _airdropBps Airdrop share in basis points
    /// @param _teamBps Team share in basis points
    /// @param _carryBps Carry-over share in basis points
    function setBps(
        uint16 _fundingRatioMinBps,
        uint16 _fundingRatioRangeBps,
        uint16 _winnerBps,
        uint16 _dividendBps,
        uint16 _airdropBps,
        uint16 _teamBps,
        uint16 _carryBps
    ) external;

    /// @notice Withdraw ERC20 tokens sent to the contract by mistake
    /// @param token Token contract address
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    function ownerWithdraw(address token, uint256 amount, address to) external;

    // ============ VRF FUNCTIONS ============

    /// @notice Request randomness for the current round
    /// @param deadline Deadline for the VRF request
    /// @return requestId The VRF request ID
    function requestRandomnessForCurrentRound(
        uint256 deadline
    ) external returns (uint256 requestId);

    // ============ VIEW FUNCTIONS ============

    /// @notice Get current round data
    /// @return startTime Round start time
    /// @return endTime Round end time
    /// @return totalPool Total prize pool
    /// @return totalParticipants Number of unique participants
    /// @return totalTickets Total tickets purchased
    /// @return lastBuyer Address of last ticket buyer
    function getCurrentRoundData()
        external
        view
        returns (
            uint64 startTime,
            uint64 endTime,
            uint256 totalPool,
            uint256 totalParticipants,
            uint256 totalTickets,
            address lastBuyer
        );

    /// @notice Get remaining seconds before round expires
    /// @return Seconds remaining (0 if round has ended)
    function getRemainingSeconds() external view returns (uint256);

    /// @notice Get current ticket price
    /// @return Current price per ticket in wei
    function getTicketPrice() external view returns (uint256);

    /// @notice Get user's ticket count in current round
    /// @param user User address to query
    /// @return Number of tickets owned by user in current round
    function getUserTicketsInCurrentRound(
        address user
    ) external view returns (uint256);

    /// @notice Get all rounds a user has participated in
    /// @param user User address to query
    /// @return Array of round IDs where user bought tickets
    function getUserParticipatedRounds(
        address user
    ) external view returns (uint256[] memory);

    /// @notice Get all participants in a specific round
    /// @param roundId Round to query
    /// @return Array of participant addresses
    function getRoundParticipants(
        uint256 roundId
    ) external view returns (address[] memory);
}
