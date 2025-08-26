// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGoatVRF, IRandomnessCallback} from "./interfaces/IGoatVrf.sol";
import {ITeamVault} from "./interfaces/ITeamVault.sol";

/// @title TimeTicket (Unlimited Mode)
/// @notice On-chain 15-minute round-based FOMO game where buying tickets extends
///         the countdown. The last buyer before expiry becomes the round winner.
///         Rounds are funded by user ticket payments and may receive additional
///         funding from a team vault using a VRF-derived ratio.
///
/// Key mechanics
/// - Rounds: 15-minute base duration; each ticket extends by `extensionPerTicket`.
/// - Fees: 0.001% charged at claim time (per payout).
/// - Distribution (from net pool): 48% winner, 20% dividends (equal split),
///   10% airdrop (random winners), 12% team (sent to `vault`), 10% carry.
/// - VRF: external randomness is supplied and used to compute the vault funding ratio.
/// - Claims: user rewards are not distributed during settlement; users claim later
///   via `claim(roundId, rewardTypes)` to avoid griefing/DoS on transfers.
/// - Payments: native ETH only. `buy` is payable and refunds overpayment.
contract TimeTicketUnlimited is IRandomnessCallback, Ownable, ReentrancyGuard {
    event RoundStarted(
        uint256 indexed roundId,
        uint64 startTime,
        uint64 endTime,
        uint256 startingTicketPrice,
        uint256 carryPool
    );
    event TicketPurchased(
        uint256 indexed roundId,
        address indexed buyer,
        uint256 quantity,
        uint256 ticketPrice,
        uint64 newEndTime
    );
    event FreeTicketClaimed(uint256 indexed roundId, address indexed user);
    event VaultFunded(
        uint256 indexed roundId,
        uint256 desiredAmount,
        uint256 injectedAmount,
        uint16 ratioBps
    );
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
    event ConfigUpdated(string key);
    event ExpiredSwept(uint256 indexed roundId, uint256 amount);

    enum RewardType {
        Winner,
        Dividend,
        Airdrop
    }

    address public authorizer;
    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 private constant CLAIM_TYPEHASH =
        keccak256(
            "ClaimFreeTicket(uint256 round,address user,uint256 deadline)"
        );

    uint256 public constant FEE_PPM = 10; // 0.001%
    uint256 public constant BASE_ROUND_DURATION = 60 minutes;
    uint256 public extensionPerTicket = 180 seconds;

    // Current ticket price (updates intra-round)
    uint256 public ticketPrice;
    // Starting price to reset to on each new round
    uint256 public startingTicketPrice;
    // Price increment added after each paid purchase (not on free claims)
    uint256 public priceIncrementPerPurchase;
    address public vault;
    address public feeRecipient;
    uint32 public airdropWinnersCount = 5;

    // VRF configuration
    address public vrfCoordinator;
    IGoatVRF public goatVrf;
    mapping(uint256 => uint256) public requestToRound;
    mapping(uint256 => uint256) public roundToRequest;
    uint256 public defaultCallbackGas = 120000;
    uint256 public defaultMaxAllowedGasPrice = 50 gwei;

    // Placeholder configuration (BPS = parts per 10_000)
    uint16 public placeholderFundingRatioMinBps = 500; // min 5%
    uint16 public placeholderFundingRatioRangeBps = 501; // range span for modulo (inclusive of +500)
    uint16 public placeholderWinnerBps = 4800; // 48%
    uint16 public placeholderDividendBps = 2000; // 20%
    uint16 public placeholderAirdropBps = 1000; // 10%
    uint16 public placeholderTeamBps = 1200; // 12%
    uint16 public placeholderCarryBps = 1000; // 10%

    struct RoundMeta {
        uint64 startTime;
        uint64 endTime;
        uint256 pool;
        uint256 totalTickets;
        address lastBuyer;
        bool settled;
        uint16 fundingRatioBps;
        address winner;
        uint256 unclaimed; // total gross claimable remaining (winner + dividends + airdrops)
    }

    uint256 public currentRoundId;
    mapping(uint256 => RoundMeta) public rounds;
    mapping(uint256 => uint256) public roundRandomness;
    mapping(uint256 => address[]) private roundParticipants;
    mapping(uint256 => mapping(address => bool)) private isParticipantInRound;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;

    // Claim bookkeeping
    mapping(uint256 => uint256) public winnerShareOfRound;
    mapping(uint256 => uint256) public dividendPerParticipant;
    mapping(uint256 => address[]) public airdropWinners;
    mapping(uint256 => mapping(address => bool)) public isAirdropWinner;
    mapping(uint256 => uint256) public airdropPerWinner;

    mapping(uint256 => bool) public claimedWinner;
    mapping(uint256 => mapping(address => bool)) public claimedDividend;
    mapping(uint256 => mapping(address => bool)) public claimedAirdrop;

    // Expiry and sweeping
    uint256 public claimExpiryRounds = 24;
    mapping(uint256 => bool) public sweptExpired;

    constructor(
        uint256 _ticketPrice,
        address _vault,
        uint256 _extensionPerTicket,
        uint32 _airdropWinnersCount,
        address _authorizer
    ) Ownable(msg.sender) {
        require(_vault != address(0), "VAULT_ZERO");
        startingTicketPrice = _ticketPrice;
        ticketPrice = startingTicketPrice;
        vault = _vault;
        extensionPerTicket = _extensionPerTicket == 0
            ? extensionPerTicket
            : _extensionPerTicket;
        airdropWinnersCount = _airdropWinnersCount == 0
            ? airdropWinnersCount
            : _airdropWinnersCount;
        feeRecipient = msg.sender;
        authorizer = _authorizer;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("TimeTicketUnlimited")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

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
        if (!isParticipantInRound[currentRoundId][msg.sender]) {
            isParticipantInRound[currentRoundId][msg.sender] = true;
            roundParticipants[currentRoundId].push(msg.sender);
        }
        ticketsOf[currentRoundId][msg.sender] += quantity;
        // After each paid purchase, increase the ticket price by configured increment
        unchecked {
            ticketPrice = ticketPrice + priceIncrementPerPurchase;
        }
        emit TicketPurchased(
            currentRoundId,
            msg.sender,
            quantity,
            ticketPrice,
            newEnd
        );
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

        // Placeholder distribution splits (in BPS)
        uint256 winnerShare = (netPool * placeholderWinnerBps) / 10_000;
        uint256 dividendPool = (netPool * placeholderDividendBps) / 10_000;
        uint256 airdropPool = (netPool * placeholderAirdropBps) / 10_000;
        uint256 teamShare = (netPool * placeholderTeamBps) / 10_000;
        uint256 carryShare = (netPool * placeholderCarryBps) / 10_000;

        address[] memory participants = roundParticipants[currentRoundId];
        uint256 participantCount = participants.length;
        uint256 undistributed = 0;

        // Winner accounting (record-only)
        if (winnerShare > 0) {
            if (rm.lastBuyer != address(0)) {
                rm.winner = rm.lastBuyer;
                winnerShareOfRound[currentRoundId] = winnerShare;
            } else {
                undistributed += winnerShare;
            }
        }

        // Dividend accounting (record-only)
        if (dividendPool > 0) {
            if (participantCount > 0) {
                uint256 perUser = dividendPool / participantCount;
                dividendPerParticipant[currentRoundId] = perUser;
                uint256 distributed = perUser * participantCount;
                if (dividendPool > distributed) {
                    undistributed += (dividendPool - distributed);
                }
            } else {
                undistributed += dividendPool;
            }
        }

        // Airdrop accounting (record-only)
        uint256 winnersCount = airdropWinnersCount;
        if (participantCount < winnersCount) {
            winnersCount = uint32(participantCount);
        }
        if (airdropPool > 0) {
            if (winnersCount > 0) {
                uint256 perWinner = airdropPool / winnersCount;
                airdropPerWinner[currentRoundId] = perWinner;
                address[] memory selected = _selectAirdropWinners(
                    participants,
                    winnersCount,
                    currentRoundId
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

        // Snapshot total unclaimed gross for this round
        uint256 winnerClaimable = rm.winner == address(0) ? 0 : winnerShare;
        uint256 dividendsClaimable = dividendPerParticipant[currentRoundId] *
            participantCount;
        uint256 airdropsClaimable = airdropPerWinner[currentRoundId] *
            airdropWinners[currentRoundId].length;
        rm.unclaimed = winnerClaimable + dividendsClaimable + airdropsClaimable;

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
            dividendPool,
            airdropPool,
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
        require(roundId >= currentRoundId - claimExpiryRounds, "ROUND_TOO_OLD");
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
            } else if (rt == RewardType.Dividend) {
                if (
                    !claimedDividend[roundId][msg.sender] &&
                    isParticipantInRound[roundId][msg.sender]
                ) {
                    uint256 gross2 = dividendPerParticipant[roundId];
                    require(gross2 > 0, "NO_DIVIDEND");
                    claimedDividend[roundId][msg.sender] = true;
                    grossPayout += gross2;
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
        require(_sendValue(msg.sender, totalPayout), "CLAIM_SEND_FAIL");
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
    /// @notice Update the EIP-712 authorizer for free ticket claims
    function setAuthorizer(address newAuthorizer) external onlyOwner {
        authorizer = newAuthorizer;
        emit ConfigUpdated("authorizer");
    }
    /// @notice Set the VRF coordinator address used to validate callbacks
    function setVrfCoordinator(address newVrf) external onlyOwner {
        vrfCoordinator = newVrf;
        emit ConfigUpdated("vrfCoordinator");
    }
    /// @notice Set the GOAT VRF contract used for randomness requests
    function setGoatVrf(address newVrf) external onlyOwner {
        require(newVrf != address(0), "ZERO_ADDR");
        goatVrf = IGoatVRF(newVrf);
        vrfCoordinator = newVrf;
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
        require(newExpiry >= 1 && newExpiry <= 365, "BAD_EXPIRY");
        claimExpiryRounds = newExpiry;
        emit ConfigUpdated("claimExpiryRounds");
    }

    // -- VRF --
    /// @notice VRF callback invoked by the coordinator with the randomness for a request
    /// @param requestId The VRF request id
    /// @param randomWord The randomness value supplied
    function receiveRandomness(uint256 requestId, uint256 randomWord) external {
        require(msg.sender == vrfCoordinator, "NOT_COORD");
        uint256 roundId = requestToRound[requestId];
        require(roundId != 0, "REQ_UNKNOWN");
        require(!rounds[roundId].settled, "ALREADY_SETTLED");
        roundRandomness[roundId] = randomWord;
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

    /// @notice Convenience method to request randomness with a default deadline
    function requestRandomnessForCurrentRoundAuto()
        external
        onlyOwner
        returns (uint256 requestId)
    {
        uint256 deadline = block.timestamp + 10 minutes;
        return this.requestRandomnessForCurrentRound(deadline);
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
    ///      exists for the round, returns placeholderFundingRatioMinBps + (rnd % placeholderFundingRatioRangeBps).
    function _getFundingRatio(uint256 roundId) internal view returns (uint16) {
        uint256 rnd = roundRandomness[roundId];
        require(rnd > 0, "NO_RANDOMNESS");
        return
            uint16(
                placeholderFundingRatioMinBps +
                    (rnd % placeholderFundingRatioRangeBps)
            );
    }

    /// @dev Internal helper to select unique airdrop winners deterministically
    function _selectAirdropWinners(
        address[] memory participants,
        uint256 winnersCount,
        uint256 roundId
    ) internal view returns (address[] memory selectedAddrs) {
        uint256 participantCount = participants.length;
        if (participantCount == 0 || winnersCount == 0) return new address[](0);
        uint256 seed = roundRandomness[roundId];
        require(seed > 0, "NO_RANDOMNESS");
        bool[] memory selected = new bool[](participantCount);
        uint256 selectedCount = 0;
        uint256 tries = 0;
        selectedAddrs = new address[](winnersCount);
        while (selectedCount < winnersCount && tries < winnersCount * 10) {
            uint256 idx = uint256(keccak256(abi.encodePacked(seed, tries))) %
                participantCount;
            if (!selected[idx]) {
                selected[idx] = true;
                selectedAddrs[selectedCount] = participants[idx];
                selectedCount++;
            }
            tries++;
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
