## Deployed Contracts

> Goat Testnet

| Contract   | Address                                    |
| ---------- | ------------------------------------------ |
| Team Vault | 0xB6182416d1b3DA8dabC3E3E166856C91e3c0063a |
| TimeTicket | 0x3773bd87bF9229e5f69D235CA0aF776A82331634 |

## Key Events

### Core Game Events

#### `TicketPurchased`

```solidity
event TicketPurchased(
    uint256 indexed roundId,
    address indexed buyer,
    uint256 quantity,
    uint256 ticketPrice,
    uint64 newEndTime
);
```

**Use Case**: Track all ticket purchases in real-time

- `roundId`: Current round identifier
- `buyer`: Address that purchased tickets
- `quantity`: Number of tickets bought
- `ticketPrice`: Price per ticket at time of purchase
- `newEndTime`: New round expiration timestamp

#### `RoundStarted`

```solidity
event RoundStarted(
    uint256 indexed roundId,
    uint64 startTime,
    uint64 endTime,
    uint256 startingTicketPrice,
    uint256 carryPool
);
```

**Use Case**: Detect when new rounds begin

- `roundId`: New round identifier
- `startTime`: Round start timestamp
- `endTime`: Initial round end timestamp (before extensions)
- `startingTicketPrice`: Initial ticket price for the round
- `carryPool`: Amount carried over from previous round

#### `RoundSettled`

```solidity
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
```

**Use Case**: Show round results and prize distribution

- `roundId`: Settled round identifier
- `winner`: Address of the round winner (last buyer)
- `totalPool`: Total pool amount before distribution
- `winnerAmount`: Amount allocated to winner (50%)
- `dividendAmount`: Total amount for participant dividends (20%)
- `airdropAmount`: Total amount for airdrop winners (10%)
- `teamAmount`: Amount sent to team vault (10%)
- `carryAmount`: Amount carried to next round (10%)

#### `VaultFunded`

```solidity
event VaultFunded(
    uint256 indexed roundId,
    uint256 desiredAmount,
    uint256 injectedAmount,
    uint16 ratioBps
);
```

**Use Case**: Track official funding injections

- `roundId`: Round that received funding
- `desiredAmount`: Amount the system wanted to inject
- `injectedAmount`: Actual amount injected (may be less if vault balance insufficient)
- `ratioBps`: VRF-generated funding ratio in basis points (5%-10%)

#### `Claimed`

```solidity
event Claimed(
    uint256 indexed roundId,
    uint256 grossPayout,
    RewardType[] rewardTypes,
    address indexed user
);
```

**Use Case**: Track user reward claims

- `roundId`: Round from which rewards were claimed
- `grossPayout`: Total gross amount before protocol fees
- `rewardTypes`: Array of reward types claimed (Winner, Dividend, Airdrop)
- `user`: Address that claimed rewards

#### `ExpiredSwept`

```solidity
event ExpiredSwept(
    uint256 indexed roundId,
    uint256 amount
);
```

**Use Case**: Track when expired unclaimed rewards are swept to vault

- `roundId`: Round whose expired rewards were swept
- `amount`: Amount swept to the team vault

### Configuration Events

#### `ConfigUpdated`

```solidity
event ConfigUpdated(string key);
```

**Use Case**: Track when game parameters change

- `key`: Parameter name that was updated (e.g., "ticketPrice", "vault", "airdropWinnersCount")

## Essential APIs

### Current Game State

#### Get Current Round Data

```solidity
function getCurrentRoundData() external view returns (
    uint64 startTime,
    uint64 endTime,
    uint256 totalPool,
    uint256 totalParticipants,
    uint256 totalTickets,
    address lastBuyer
);
```

**Use Case**: Display current round status

- Returns complete current round information
- `totalParticipants`: Number of unique addresses that bought tickets
- `totalTickets`: Total tickets sold this round
- `lastBuyer`: Current leader (potential winner)

#### Get Remaining Time

```solidity
function getRemainingSeconds() external view returns (uint256);
```

**Use Case**: Show countdown timer

- Returns seconds until round expires (0 if already expired)

#### Get Current Ticket Price

```solidity
function getTicketPrice() external view returns (uint256);
```

**Use Case**: Display current ticket price

- Price increases after each purchase by `priceIncrementPerPurchase`
- Resets to `startingTicketPrice` each new round

### User-Specific Data

#### Get User's Tickets in Current Round

```solidity
function getUserTicketsInCurrentRound(address user) external view returns (uint256);
```

**Use Case**: Show user's participation in current round

#### Get User's Tickets in Any Round

```solidity
function ticketsOf(uint256 roundId, address user) external view returns (uint256);
```

**Use Case**: Show user's historical participation

- `roundId`: Round to query
- `user`: User address to check

#### Get User's Total Claims

```solidity
function totalClaimed(address user) external view returns (uint256);
```

**Use Case**: Show user's total historical winnings

#### Get User's Participated Rounds

```solidity
function getUserParticipatedRounds(address user) external view returns (uint256[] memory);
```

**Use Case**: Get complete participation history for a user

- Returns array of round IDs where user bought tickets
- Useful for displaying user's game history and potential claims

### Reward Checking

#### Check Claim Status

```solidity
// For winner rewards
function claimedWinner(uint256 roundId) external view returns (bool);

// For dividend rewards
function claimedDividend(uint256 roundId, address user) external view returns (bool);

// For airdrop rewards
function claimedAirdrop(uint256 roundId, address user) external view returns (bool);
```

**Use Case**: Check if user has already claimed specific reward types

#### Check Airdrop Winner Status

```solidity
function isAirdropWinner(uint256 roundId, address user) external view returns (bool);
```

**Use Case**: Check if user won airdrop for a specific round

#### Get Round Winners

```solidity
function airdropWinners(uint256 roundId, uint256 index) external view returns (address);
```

**Use Case**: Get specific airdrop winner by index

- `roundId`: Round to query
- `index`: Index of the airdrop winner (0-based)

**Note**: To get all airdrop winners, iterate from index 0 until you reach `airdropWinnersCount`

### Round Information

#### Get Round Details

```solidity
function rounds(uint256 roundId) external view returns (
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
```

**Use Case**: Get complete information about any round

- `settled`: Whether round has been settled
- `fundingRatioBps`: Actual funding ratio used (basis points)
- `winner`: Winner address (same as lastBuyer)
- `unclaimed`: Remaining unclaimed rewards

#### Get Round Participants

```solidity
function getRoundParticipants(uint256 roundId) external view returns (address[]);
```

**Use Case**: Display all participants (may be large array)

- Returns array of all unique addresses that bought tickets

### Reward Amounts

#### Get Reward Amounts

```solidity
// Winner share for a round
function winnerShareOfRound(uint256 roundId) external view returns (uint256);

// Dividend amount per participant
function dividendPerParticipant(uint256 roundId) external view returns (uint256);

// Airdrop amount per winner
function airdropPerWinner(uint256 roundId) external view returns (uint256);
```

**Use Case**: Calculate potential rewards before claiming

### VRF and Randomness

#### Check VRF Request Status

```solidity
// Get VRF request ID for a round
function roundToRequest(uint256 roundId) external view returns (uint256);

// Get round ID for a VRF request
function requestToRound(uint256 requestId) external view returns (uint256);

// Get randomness value for a round
function roundRandomness(uint256 roundId) external view returns (uint256);
```

**Use Case**: Monitor VRF status and verify randomness availability

### Expiry Management

#### Check Sweep Status

```solidity
function sweptExpired(uint256 roundId) external view returns (bool);
```

**Use Case**: Check if expired rewards have been swept to vault

## Key State Variables

```solidity
// Current game state
uint256 public currentRoundId;           // Current active round
uint256 public ticketPrice;              // Current ticket price (dynamic)
uint256 public startingTicketPrice;      // Reset price for each round
uint256 public priceIncrementPerPurchase; // Price increase per purchase

// Game configuration
uint256 public extensionPerTicket;       // Seconds added per ticket (default: 180)
uint32 public airdropWinnersCount;       // Number of airdrop winners (default: 5)
address public vault;                    // Team vault address
address public feeRecipient;             // Protocol fee recipient

// Distribution percentages (in basis points, 10000 = 100%)
uint16 public winnerBps;    // Winner share (default: 5000 = 50%)
uint16 public dividendBps;  // Participant dividends (default: 2000 = 20%)
uint16 public airdropBps;   // Airdrop pool (default: 1000 = 10%)
uint16 public teamBps;      // Team share (default: 1000 = 10%)
uint16 public carryBps;     // Carry to next round (default: 1000 = 10%)

// User participation tracking
mapping(address => uint256[]) public userRounds; // All rounds a user participated in

// Claim expiry configuration
uint256 public claimExpiryRounds;   // Rounds after which claims expire (default: 24)

// VRF funding configuration
uint16 public fundingRatioMinBps;   // Min funding ratio (default: 500 = 5%)
uint16 public fundingRatioRangeBps; // Funding range (default: 501 = 5.01%)
uint256 public defaultCallbackGas;  // VRF callback gas limit
uint256 public defaultMaxAllowedGasPrice; // VRF max gas price (default: 50 gwei)
```

## Contract Functions for User Actions

### Buy Tickets

```solidity
function buy(
    uint256 quantity,
    uint256 maxTotalCost,
    uint256 deadline
) external payable;
```

**Parameters**:

- `quantity`: Number of tickets to buy
- `maxTotalCost`: Maximum willing to pay (slippage protection)
- `deadline`: Transaction expiry timestamp
- `msg.value`: ETH amount (must be >= actual cost, excess refunded)

### Claim Rewards

```solidity
enum RewardType { Winner, Dividend, Airdrop }

function claim(
    uint256 roundId,
    RewardType[] calldata rewardTypes
) external;
```

**Parameters**:

- `roundId`: Round to claim rewards from
- `rewardTypes`: Array of reward types to claim

**Important**: Rewards are **EXCLUSIVE** - users can only claim ONE type per round:

- **Winner**: Final winner gets 50% of net pool (highest priority)
- **Airdrop**: Random winners get 10% split (excludes final winner)
- **Dividend**: All other participants get 20% split (excludes winner & airdrop winners)

### Sweep Expired Rewards

```solidity
function sweepExpired(uint256 roundId) external;
```

**Use Case**: Manually sweep expired unclaimed rewards to the team vault

- `roundId`: Round whose expired rewards should be swept
- Claims expire after `claimExpiryRounds` rounds (default: 24)
- Only works if the round has expired and hasn't been swept yet

### Request VRF Randomness

```solidity
function requestRandomnessForCurrentRound(uint256 deadline) external returns (uint256 requestId);
```

**Use Case**: Request VRF randomness for funding ratio and airdrop selection

- `deadline`: Deadline for the VRF request
- Returns the VRF request ID
- Must be called before settlement to enable VRF-based features

## Constants

```solidity
uint256 public constant FEE_PPM = 10;                    // 0.001% protocol fee
uint256 public constant BASE_ROUND_DURATION = 60 minutes; // Base round duration
```

## Error Codes

Common revert reasons:

- `QTY_ZERO`: Ticket quantity must be > 0
- `EXPIRED`: Transaction deadline passed
- `PRICE_SLIPPAGE`: Current price exceeds maxTotalCost
- `INSUFFICIENT_MSG_VALUE`: Not enough ETH sent
- `REFUND_FAIL`: Failed to refund excess payment
- `ROUND_SETTLED`: Cannot buy tickets in settled round
- `ROUND_NOT_OVER`: Cannot settle active round
- `ROUND_NOT_SETTLED`: Cannot claim from unsettled round
- `NO_RANDOMNESS`: VRF randomness not available
- `NOTHING_TO_CLAIM`: No claimable rewards
- `VAULT_ZERO`: Invalid vault address
- `WINNER_NOT_AT_END`: Internal error - winner optimization failed
- `ALREADY_SWEPT`: Round rewards already swept
- `NOT_EXPIRED`: Round claims not yet expired

This documentation provides all the essential information for frontend developers to integrate with the TimeTicket contract effectively.
