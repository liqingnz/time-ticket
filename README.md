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
    uint256 dividendAmount,
    uint256 airdropAmount,
    uint256 teamAmount,
    uint256 carryAmount
);
```

**Use Case**: Show round results and prize distribution

- `roundId`: Settled round identifier
- `winner`: Address of the round winner (last buyer)
- `totalPool`: Total pool amount before distribution
- `winnerAmount`: Amount allocated to winner (48%)
- `dividendAmount`: Total amount for participant dividends (20%)
- `airdropAmount`: Total amount for airdrop winners (10%)
- `teamAmount`: Amount sent to team vault (12%)
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
function airdropWinners(uint256 roundId) external view returns (address[]);
```

**Use Case**: Display all airdrop winners for a round

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
uint16 public winnerBps;    // Winner share (default: 4800 = 48%)
uint16 public dividendBps;  // Participant dividends (default: 2000 = 20%)
uint16 public airdropBps;   // Airdrop pool (default: 1000 = 10%)
uint16 public teamBps;      // Team share (default: 1200 = 12%)
uint16 public carryBps;     // Carry to next round (default: 1000 = 10%)

// VRF funding configuration
uint16 public fundingRatioMinBps;   // Min funding ratio (default: 500 = 5%)
uint16 public fundingRatioRangeBps; // Funding range (default: 501 = 5.01%)
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
- `rewardTypes`: Array of reward types to claim (can claim multiple at once)

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
- `ROUND_SETTLED`: Cannot buy tickets in settled round
- `ROUND_NOT_OVER`: Cannot settle active round
- `NO_RANDOMNESS`: VRF randomness not available
- `NOTHING_TO_CLAIM`: No claimable rewards
- `VAULT_ZERO`: Invalid vault address

This documentation provides all the essential information for frontend developers to integrate with the TimeTicket contract effectively.
