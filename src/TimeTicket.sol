// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IGoatVRF, IRandomnessCallback} from "./interfaces/IGoatVrf.sol";
import {ITeamVault} from "./interfaces/ITeamVault.sol";
import {ITimeTicket} from "./interfaces/ITimeTicket.sol";

/// @title TimeTicket (Upgradeable)
/// @notice On-chain 60-minute round-based FOMO game where buying tickets extends
///         the countdown. The last buyer before expiry becomes the round winner.
///         Rounds are funded by user ticket payments and may receive additional
///         funding from a team vault using a VRF-derived ratio.
///
/// Key mechanics
/// - Rounds: 60-minute base duration; each ticket extends by `extensionPerTicket`.
/// - Fees: 0.001% charged at claim time (per payout).
/// - Distribution (from net pool): 48% winner, 20% dividends (equal split),
///   10% airdrop (random winners), 12% team (sent to `vault`), 10% carry.
/// - VRF: external randomness is supplied and used to compute the vault funding ratio.
/// - Claims: user rewards are not distributed during settlement; users claim later
///   via `claim(roundId, rewardTypes)` to avoid griefing/DoS on transfers.
/// - Payments: native ETH only. `buy` is payable and refunds overpayment.
contract TimeTicketUpgradeable is
    ITimeTicket,
    IRandomnessCallback,
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public constant FEE_PPM = 10; // 0.001%
    uint256 public constant BASE_ROUND_DURATION = 60 minutes;
    uint256 public extensionPerTicket;

    // Current ticket price (updates intra-round)
    uint256 public ticketPrice;
    // Starting price to reset to on each new round
    uint256 public startingTicketPrice;
    // Price increment added after each paid purchase (not on free claims)
    uint256 public priceIncrementPerPurchase;
    address public vault;
    address public feeRecipient;
    uint32 public airdropWinnersCount;

    // VRF configuration
    IGoatVRF public goatVrf;
    mapping(uint256 => uint256) public requestToRound;
    mapping(uint256 => uint256) public roundToRequest;
    uint256 public defaultCallbackGas;
    uint256 public defaultMaxAllowedGasPrice;

    // Distribution configuration (BPS = parts per 10_000)
    uint16 public fundingRatioMinBps;
    uint16 public fundingRatioRangeBps;
    uint16 public winnerBps;
    uint16 public airdropBps;
    uint16 public dividendBps;
    uint16 public teamBps;
    uint16 public carryBps;

    uint256 public currentRoundId;
    mapping(uint256 => RoundMeta) public rounds;
    mapping(uint256 => uint256) public roundRandomness;
    mapping(uint256 => address[]) private roundParticipants;
    mapping(uint256 => mapping(address => uint256)) private participantIndex;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;
    mapping(address => uint256[]) public userRounds;

    // Claim bookkeeping
    mapping(uint256 => uint256) public winnerShareOfRound;
    mapping(uint256 => uint256) public dividendPerParticipant;
    mapping(uint256 => address[]) public airdropWinners;
    mapping(uint256 => mapping(address => bool)) public isAirdropWinner;
    mapping(uint256 => uint256) public airdropPerWinner;

    mapping(uint256 => bool) public claimedWinner;
    mapping(uint256 => mapping(address => bool)) public claimedDividend;
    mapping(uint256 => mapping(address => bool)) public claimedAirdrop;
    mapping(address => uint256) public totalClaimed;

    // Expiry and sweeping
    uint256 public claimExpiryRounds;
    mapping(uint256 => bool) public sweptExpired;

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 _ticketPrice,
        address _vault,
        address _goatVrf
    ) public initializer {
        require(_vault != address(0), "VAULT_ZERO");
        require(_goatVrf != address(0), "VRF_ZERO");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        startingTicketPrice = _ticketPrice;
        ticketPrice = startingTicketPrice;
        vault = _vault;
        goatVrf = IGoatVRF(_goatVrf);
        feeRecipient = msg.sender;

        // Initialize default distribution values
        extensionPerTicket = 180;
        airdropWinnersCount = 5;
        fundingRatioMinBps = 500; // 5%
        fundingRatioRangeBps = 501; // range span
        winnerBps = 5000; // 50%
        airdropBps = 1000; // 10%
        dividendBps = 2000; // 20%
        teamBps = 1000; // 10%
        carryBps = 1000; // 10%

        // Initialize other defaults
        claimExpiryRounds = 24;
        defaultCallbackGas = 120000;
        defaultMaxAllowedGasPrice = 0.006 gwei;

        _startNextRound(0);
    }

    receive() external payable {}

    /// @notice Buy tickets with native ETH, protected by max total cost and deadline.
    /// @dev Refunds any overpayment to the caller.
    /// @param quantity Number of tickets to buy
    /// @param maxTotalCost Maximum total cost the user accepts (slippage guard)
    /// @param deadline Latest acceptable timestamp for the purchase
    function buy(
        uint256 quantity,
        uint256 maxTotalCost,
        uint256 deadline
    ) external payable nonReentrant {
        require(quantity > 0, "QTY_ZERO");
        require(block.timestamp <= deadline, "EXPIRED");
        RoundMeta storage rm = rounds[currentRoundId];
        require(!rm.settled, "ROUND_SETTLED");
        require(block.timestamp <= rm.endTime, "ROUND_ENDED");
        uint256 cost = ticketPrice * quantity;
        require(cost <= maxTotalCost, "PRICE_SLIPPAGE");
        require(msg.value >= cost, "INSUFFICIENT_MSG_VALUE");
        uint256 change = msg.value - cost;
        if (change > 0) {
            require(_sendValue(msg.sender, change), "REFUND_FAIL");
        }
        uint64 newEnd = rm.endTime + uint64(extensionPerTicket * quantity);
        rm.endTime = newEnd;
        rm.pool += cost;
        rm.totalTickets += quantity;
        rm.lastBuyer = msg.sender;
        uint256 currentIndex = participantIndex[currentRoundId][msg.sender];
        if (currentIndex == 0) {
            // New participant: add to array and store 1-based index
            roundParticipants[currentRoundId].push(msg.sender);
            participantIndex[currentRoundId][msg.sender] = roundParticipants[
                currentRoundId
            ].length;
            userRounds[msg.sender].push(currentRoundId);
        } else {
            // Existing participant: move to end of array for winner optimization
            address[] storage participants = roundParticipants[currentRoundId];
            uint256 lastIndex = participants.length - 1;
            uint256 userIndex = currentIndex - 1; // Convert to 0-based

            if (userIndex != lastIndex) {
                // Swap current user with last participant
                address lastParticipant = participants[lastIndex];
                participants[userIndex] = lastParticipant;
                participants[lastIndex] = msg.sender;

                // Update the swapped participant's index
                participantIndex[currentRoundId][
                    lastParticipant
                ] = currentIndex;
                participantIndex[currentRoundId][msg.sender] = lastIndex + 1;
            }
        }
        ticketsOf[currentRoundId][msg.sender] += quantity;
        emit TicketPurchased(
            currentRoundId,
            msg.sender,
            quantity,
            ticketPrice,
            newEnd
        );
        // After each paid purchase, increase the ticket price by configured increment
        unchecked {
            ticketPrice = ticketPrice + priceIncrementPerPurchase;
        }
    }

    /// @notice Settle the current round after it ends. No user transfers occur here; all
    ///         rewards are recorded for later claims. Team share is sent to the vault.
    function settle() external nonReentrant {
        RoundMeta storage rm = rounds[currentRoundId];
        require(!rm.settled, "ROUND_SETTLED");
        require(block.timestamp > rm.endTime, "ROUND_NOT_OVER");
        // Compute funding ratio via helper (uses VRF if present; else placeholder)
        uint16 ratioBps = _getFundingRatio(currentRoundId);
        rm.fundingRatioBps = ratioBps;
        uint256 desiredInjection = (rm.pool * ratioBps) / 10_000;
        uint256 injected = 0;
        if (desiredInjection > 0 && vault != address(0)) {
            uint256 balBefore = address(this).balance;
            // Preferred path: call TeamVault.Fund(amount)
            try ITeamVault(vault).Fund(desiredInjection) {
                // no-op
            } catch {}
            uint256 balAfter = address(this).balance;
            if (balAfter > balBefore) {
                injected = balAfter - balBefore;
                rm.pool += injected;
            }
        }
        emit VaultFunded(currentRoundId, desiredInjection, injected, ratioBps);

        uint256 netPool = rm.pool;
        // Distribution splits (in BPS)
        uint256 winnerShare = (netPool * winnerBps) / 10_000;
        uint256 dividendPool = (netPool * dividendBps) / 10_000;
        uint256 airdropPool = (netPool * airdropBps) / 10_000;
        uint256 teamShare = (netPool * teamBps) / 10_000;
        uint256 carryShare = (netPool * carryBps) / 10_000;

        address[] memory participants = roundParticipants[currentRoundId];
        uint256 participantCount = participants.length;
        uint256 undistributed = 0;

        if (participantCount > 0) {
            // Winner accounting (record-only)
            bool hasWinner = winnerShare > 0;
            if (hasWinner) {
                rm.winner = rm.lastBuyer;
                winnerShareOfRound[currentRoundId] = winnerShare;
            }

            // Airdrop accounting (record-only) - exclude final winner from airdrop selection
            uint256 winnersCount = airdropWinnersCount;
            uint256 airdropCandidates = participantCount - (hasWinner ? 1 : 0);
            if (airdropCandidates < winnersCount) {
                winnersCount = airdropCandidates;
            }
            if (airdropPool > 0) {
                if (winnersCount > 0) {
                    uint256 perWinner = airdropPool / winnersCount;
                    airdropPerWinner[currentRoundId] = perWinner;
                    address[] memory selected = _selectAirdropWinners(
                        participants,
                        winnersCount,
                        currentRoundId,
                        hasWinner ? rm.winner : address(0) // Exclude winner only if any
                    );
                    airdropWinners[currentRoundId] = selected;
                    for (uint256 i = 0; i < selected.length; i++) {
                        isAirdropWinner[currentRoundId][selected[i]] = true;
                    }
                    uint256 distributed2 = perWinner * selected.length;
                    if (airdropPool > distributed2) {
                        undistributed += (airdropPool - distributed2);
                    }
                } else {
                    undistributed += airdropPool;
                }
            }

            // Dividend accounting (record-only)
            // Calculate eligible dividend participants (exclude final winner and airdrop winners)
            uint256 eligibleDividendParticipants = participantCount -
                (hasWinner ? 1 : 0);
            if (winnersCount > 0) {
                eligibleDividendParticipants -= winnersCount;
            }
            if (dividendPool > 0) {
                if (eligibleDividendParticipants > 0) {
                    uint256 perUser = dividendPool /
                        eligibleDividendParticipants;
                    dividendPerParticipant[currentRoundId] = perUser;
                    uint256 distributed = perUser *
                        eligibleDividendParticipants;
                    if (dividendPool > distributed) {
                        undistributed += (dividendPool - distributed);
                    }
                } else {
                    undistributed += dividendPool;
                }
            }

            // Snapshot total unclaimed gross for this round
            uint256 airdropsClaimable = airdropPerWinner[currentRoundId] *
                airdropWinners[currentRoundId].length;
            uint256 dividendsClaimable = dividendPerParticipant[
                currentRoundId
            ] * eligibleDividendParticipants;
            uint256 winnerClaimable = hasWinner ? winnerShare : 0;
            rm.unclaimed =
                winnerClaimable +
                dividendsClaimable +
                airdropsClaimable;
        } else {
            undistributed = netPool - teamShare - carryShare;
        }

        // Team share: attempt immediate transfer to the vault. If it fails, add to carry.
        if (teamShare > 0) {
            if (vault != address(0)) {
                if (!_sendValue(vault, teamShare)) {
                    undistributed += teamShare;
                }
            } else {
                undistributed += teamShare;
            }
        }

        uint256 carryPool = carryShare + undistributed;
        rm.settled = true;
        emit RoundSettled(
            currentRoundId,
            rm.winner,
            rm.pool,
            winnerShare,
            airdropPool,
            dividendPool,
            teamShare,
            carryPool
        );
        _startNextRound(carryPool);

        // Auto-sweep an expired round, if any
        if (currentRoundId > claimExpiryRounds + 1) {
            uint256 sweepRound = currentRoundId - (claimExpiryRounds + 1);
            _sweepExpiredInternal(sweepRound);
        }
    }

    function claim(
        uint256 roundId,
        RewardType[] calldata rewardTypes
    ) external nonReentrant {
        require(rounds[roundId].settled, "ROUND_NOT_SETTLED");
        uint256 totalPayout = 0;
        uint256 grossPayout = 0;
        for (uint256 i = 0; i < rewardTypes.length; i++) {
            RewardType rt = rewardTypes[i];
            if (rt == RewardType.Winner) {
                if (
                    !claimedWinner[roundId] &&
                    rounds[roundId].winner == msg.sender
                ) {
                    uint256 gross = winnerShareOfRound[roundId];
                    require(gross > 0, "NO_WINNER_AMT");
                    claimedWinner[roundId] = true;
                    grossPayout += gross;
                }
            } else if (rt == RewardType.Airdrop) {
                if (
                    !claimedAirdrop[roundId][msg.sender] &&
                    isAirdropWinner[roundId][msg.sender]
                ) {
                    uint256 gross3 = airdropPerWinner[roundId];
                    require(gross3 > 0, "NO_AIRDROP");
                    claimedAirdrop[roundId][msg.sender] = true;
                    grossPayout += gross3;
                }
            } else if (rt == RewardType.Dividend) {
                if (
                    !claimedDividend[roundId][msg.sender] &&
                    participantIndex[roundId][msg.sender] > 0 &&
                    rounds[roundId].winner != msg.sender && // Exclude final winner
                    !isAirdropWinner[roundId][msg.sender] // Exclude airdrop winners
                ) {
                    uint256 gross2 = dividendPerParticipant[roundId];
                    require(gross2 > 0, "NO_DIVIDEND");
                    claimedDividend[roundId][msg.sender] = true;
                    grossPayout += gross2;
                }
            }
        }
        require(grossPayout > 0, "NOTHING_TO_CLAIM");
        // Deduct from round's unclaimed total before external calls
        RoundMeta storage rmC = rounds[roundId];
        require(rmC.unclaimed >= grossPayout, "OVERCLAIM");
        unchecked {
            rmC.unclaimed = rmC.unclaimed - grossPayout;
        }
        uint256 fee = (grossPayout * FEE_PPM) / 1_000_000;
        totalPayout = grossPayout - fee;
        if (fee > 0 && feeRecipient != address(0)) {
            require(_sendValue(feeRecipient, fee), "FEE_SEND_FAIL");
        }
        totalClaimed[msg.sender] += totalPayout;
        require(_sendValue(msg.sender, totalPayout), "CLAIM_SEND_FAIL");
        emit Claimed(roundId, grossPayout, rewardTypes, msg.sender);
    }

    /// @notice Manually sweep an expired round's unclaimed rewards to the vault
    function sweepExpired(uint256 roundId) external nonReentrant {
        _sweepExpiredInternal(roundId);
    }

    function _sweepExpiredInternal(uint256 roundId) internal {
        if (sweptExpired[roundId]) return;
        RoundMeta storage rm = rounds[roundId];
        require(rm.settled, "ROUND_NOT_SETTLED");
        require(currentRoundId > roundId + claimExpiryRounds, "NOT_EXPIRED");
        uint256 amount = rm.unclaimed;
        if (amount == 0) {
            sweptExpired[roundId] = true;
            emit ExpiredSwept(roundId, 0);
            return;
        }
        rm.unclaimed = 0;
        require(vault != address(0), "VAULT_ZERO");
        require(_sendValue(vault, amount), "SWEEP_SEND_FAIL");
        sweptExpired[roundId] = true;
        emit ExpiredSwept(roundId, amount);
    }

    // -- Config --
    /// @notice Set or update the team vault address (receives team share, funds rounds)
    function setVault(address newVault) external onlyOwner {
        require(newVault != address(0), "ZERO_ADDR");
        vault = newVault;
        emit ConfigUpdated("vault");
    }
    /// @notice Set the starting ticket price for each new round
    function setStartingTicketPrice(
        uint256 newStartingPrice
    ) external onlyOwner {
        startingTicketPrice = newStartingPrice;
        emit ConfigUpdated("startingTicketPrice");
    }
    /// @notice Set the increment amount added to price after each paid purchase
    function setPriceIncrementPerPurchase(
        uint256 newIncrement
    ) external onlyOwner {
        priceIncrementPerPurchase = newIncrement;
        emit ConfigUpdated("priceIncrementPerPurchase");
    }
    /// @notice Update the default number of airdrop winners per round
    function setAirdropWinnersCount(uint32 newCount) external onlyOwner {
        require(newCount <= 1000, "TOO_MANY");
        airdropWinnersCount = newCount;
        emit ConfigUpdated("airdropWinnersCount");
    }
    /// @notice Update the per-ticket extension duration
    function setExtensionPerTicket(uint256 newExtension) external onlyOwner {
        require(newExtension > 0 && newExtension <= 1 hours, "BAD_EXT");
        extensionPerTicket = newExtension;
        emit ConfigUpdated("extensionPerTicket");
    }
    /// @notice Update the protocol fee recipient
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "ZERO_ADDR");
        feeRecipient = newRecipient;
        emit ConfigUpdated("feeRecipient");
    }
    /// @notice Set the GOAT VRF contract used for randomness requests
    function setGoatVrf(address newVrf) external onlyOwner {
        require(newVrf != address(0), "ZERO_ADDR");
        goatVrf = IGoatVRF(newVrf);
        emit ConfigUpdated("goatVrf");
    }
    /// @notice Update default VRF parameters used for fee estimation and callback gas
    function setDefaultVrfParams(
        uint256 callbackGas,
        uint256 maxAllowedGasPrice
    ) external onlyOwner {
        require(callbackGas >= 60_000 && callbackGas <= 500_000, "BAD_GAS");
        require(maxAllowedGasPrice > 0, "BAD_GPRICE");
        defaultCallbackGas = callbackGas;
        defaultMaxAllowedGasPrice = maxAllowedGasPrice;
        emit ConfigUpdated("vrfParams");
    }

    /// @notice Recover stray ERC20 tokens sent to this contract
    function ownerWithdraw(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        require(to != address(0), "ZERO_ADDR");
        IERC20(token).transfer(to, amount);
    }

    /// @notice Update the number of rounds after which unclaimed rewards expire
    function setClaimExpiryRounds(uint256 newExpiry) external onlyOwner {
        require(newExpiry >= 1, "BAD_EXPIRY");
        claimExpiryRounds = newExpiry;
        emit ConfigUpdated("claimExpiryRounds");
    }

    /// @notice Update distribution parameters in basis points (BPS, where 10000 = 100%)
    /// @param _fundingRatioMinBps Minimum funding ratio (e.g., 500 = 5%)
    /// @param _fundingRatioRangeBps Range for VRF randomness (e.g., 501 = 5.01%)
    /// @param _winnerBps Winner share percentage (e.g., 4800 = 48%)
    /// @param _dividendBps Dividend share percentage (e.g., 2000 = 20%)
    /// @param _airdropBps Airdrop share percentage (e.g., 1000 = 10%)
    /// @param _teamBps Team share percentage (e.g., 1200 = 12%)
    /// @param _carryBps Carry-over share percentage (e.g., 1000 = 10%)
    function setBps(
        uint16 _fundingRatioMinBps,
        uint16 _fundingRatioRangeBps,
        uint16 _winnerBps,
        uint16 _dividendBps,
        uint16 _airdropBps,
        uint16 _teamBps,
        uint16 _carryBps
    ) external onlyOwner {
        require(_fundingRatioMinBps <= 10000, "INVALID_FUNDING_MIN_BPS");
        require(
            _fundingRatioRangeBps > 0 && _fundingRatioRangeBps <= 10000,
            "INVALID_FUNDING_RANGE_BPS"
        );
        require(_winnerBps <= 10000, "INVALID_WINNER_BPS");
        require(_dividendBps <= 10000, "INVALID_DIVIDEND_BPS");
        require(_airdropBps <= 10000, "INVALID_AIRDROP_BPS");
        require(_teamBps <= 10000, "INVALID_TEAM_BPS");
        require(_carryBps <= 10000, "INVALID_CARRY_BPS");

        fundingRatioMinBps = _fundingRatioMinBps;
        fundingRatioRangeBps = _fundingRatioRangeBps;
        winnerBps = _winnerBps;
        dividendBps = _dividendBps;
        airdropBps = _airdropBps;
        teamBps = _teamBps;
        carryBps = _carryBps;

        emit ConfigUpdated("distributionBps");
    }

    // -- VRF --
    /// @notice VRF callback invoked by the coordinator with the randomness for a request
    /// @param requestId The VRF request id
    /// @param randomness The randomness value supplied
    function receiveRandomness(uint256 requestId, uint256 randomness) external {
        require(msg.sender == address(goatVrf), "NOT_COORD");
        uint256 roundId = requestToRound[requestId];
        require(roundId != 0, "REQ_UNKNOWN");
        require(!rounds[roundId].settled, "ALREADY_SETTLED");
        roundRandomness[roundId] = randomness;
    }

    /// @notice Request randomness for the current round (owner-only)
    /// @param deadline The VRF request deadline
    function requestRandomnessForCurrentRound(
        uint256 deadline
    ) external onlyOwner returns (uint256 requestId) {
        require(address(goatVrf) != address(0), "VRF_NOT_SET");
        uint256 roundId = currentRoundId;
        require(roundToRequest[roundId] == 0, "ALREADY_REQ");
        require(roundRandomness[roundId] == 0, "ALREADY_HAVE");
        address feeToken = goatVrf.feeToken();
        uint256 expectedFee = goatVrf.calculateFeeWithGasPrice(
            defaultCallbackGas,
            defaultMaxAllowedGasPrice
        );
        if (feeToken != address(0) && expectedFee > 0) {
            IERC20(feeToken).approve(address(goatVrf), 0);
            IERC20(feeToken).approve(address(goatVrf), expectedFee);
        }
        requestId = goatVrf.getNewRandom(
            deadline,
            defaultMaxAllowedGasPrice,
            defaultCallbackGas
        );
        requestToRound[requestId] = roundId;
        roundToRequest[roundId] = requestId;
    }

    // -- Public Getters --
    /// @notice Get public state for the current active round
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
        )
    {
        RoundMeta storage rm = rounds[currentRoundId];
        startTime = rm.startTime;
        endTime = rm.endTime;
        totalPool = rm.pool;
        totalParticipants = roundParticipants[currentRoundId].length;
        totalTickets = rm.totalTickets;
        lastBuyer = rm.lastBuyer;
    }

    /// @notice Seconds remaining before the current round expires (0 if ended)
    function getRemainingSeconds() external view returns (uint256) {
        RoundMeta storage rm = rounds[currentRoundId];
        if (block.timestamp >= rm.endTime) return 0;
        return rm.endTime - block.timestamp;
    }

    /// @notice Current ticket price (in wei)
    function getTicketPrice() external view returns (uint256) {
        return ticketPrice;
    }

    /// @notice Get the user's ticket count for the current round
    function getUserTicketsInCurrentRound(
        address user
    ) external view returns (uint256) {
        return ticketsOf[currentRoundId][user];
    }

    /// @notice Get all rounds that a user has participated in
    function getUserParticipatedRounds(
        address user
    ) external view returns (uint256[] memory) {
        return userRounds[user];
    }

    /// @notice Get the participant addresses for a given round (may be large)
    function getRoundParticipants(
        uint256 roundId
    ) external view returns (address[] memory) {
        return roundParticipants[roundId];
    }

    // -- Internal Helpers --
    /// @dev Internal helper to start the next round with an optional carry pool
    function _startNextRound(uint256 carryPool) internal {
        ++currentRoundId;
        RoundMeta storage rm = rounds[currentRoundId];
        rm.startTime = uint64(block.timestamp);
        rm.endTime = uint64(block.timestamp + BASE_ROUND_DURATION);
        rm.pool = carryPool;
        // Reset ticket price to starting price for the new round
        ticketPrice = startingTicketPrice;
        emit RoundStarted(
            currentRoundId,
            rm.startTime,
            rm.endTime,
            startingTicketPrice,
            carryPool
        );
    }

    /// @dev Internal helper that derives the funding ratio (e.g., 5%-10%). If randomness
    ///      exists for the round, returns fundingRatioMinBps + (rnd % fundingRatioRangeBps).
    function _getFundingRatio(uint256 roundId) internal view returns (uint16) {
        uint256 rnd = roundRandomness[roundId];
        require(rnd > 0, "NO_RANDOMNESS");
        require(fundingRatioRangeBps > 0, "INVALID_FUNDING_RANGE");
        return uint16(fundingRatioMinBps + (rnd % fundingRatioRangeBps));
    }

    /// @dev Internal helper to select unique airdrop winners deterministically
    /// @param participants List of all participants
    /// @param winnersCount Number of airdrop winners to select
    /// @param roundId Round ID for randomness
    /// @param finalWinner Address of final winner to exclude from airdrop selection
    function _selectAirdropWinners(
        address[] memory participants,
        uint256 winnersCount,
        uint256 roundId,
        address finalWinner
    ) internal view returns (address[] memory selectedAddrs) {
        uint256 n = participants.length;
        if (n == 0 || winnersCount == 0) return new address[](0);
        uint256 seed = roundRandomness[roundId];
        require(seed > 0, "NO_RANDOMNESS");

        // Optimization: winner is always at the last index due to buy() logic
        // No need to search for winner index - just exclude last element if winner exists
        uint256 upperBound = n;
        if (finalWinner != address(0)) {
            // Winner should be at last index, but verify for safety
            require(participants[n - 1] == finalWinner, "WINNER_NOT_AT_END");
            upperBound = n - 1; // exclude last index (winner)
        }

        // Ensure we don't try to select more winners than available candidates
        if (winnersCount > upperBound) {
            winnersCount = upperBound;
        }

        // Partial Fisher–Yates: pick first winnersCount by swapping from [i, upperBound)
        for (uint256 i = 0; i < winnersCount; i++) {
            // advance seed deterministically per step
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 range = upperBound - i; // remaining candidates
            uint256 j = i + (seed % range); // j in [i, upperBound)
            // swap participants[i] and participants[j]
            if (j != i) {
                address t = participants[i];
                participants[i] = participants[j];
                participants[j] = t;
            }
        }

        // Collect first winnersCount addresses as winners
        selectedAddrs = new address[](winnersCount);
        for (uint256 k = 0; k < winnersCount; k++) {
            selectedAddrs[k] = participants[k];
        }
    }

    /// @dev Safe native ETH send wrapper; returns false if the call fails
    function _sendValue(address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, ) = payable(to).call{value: amount}("");
        return ok;
    }

    /// @dev Recover ECDSA signer from a digest and signature
    function _recoverSigner(
        bytes32 digest,
        bytes memory signature
    ) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
