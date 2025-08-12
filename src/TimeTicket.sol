// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGoatVRF, IRandomnessCallback, IDrandBeacon} from "./interfaces/IGoatVrf.sol";

contract TimeTicket is IRandomnessCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Events ----
    event RoundStarted(
        uint256 indexed roundId,
        uint64 startTime,
        uint64 endTime,
        uint256 carryPool
    );
    event TicketPurchased(
        uint256 indexed roundId,
        address indexed buyer,
        uint256 quantity,
        uint256 paidAmount,
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

    // ---- Config ----
    uint256 public constant BASE_ROUND_DURATION = 15 minutes;
    uint256 public constant MAX_ROUND_DURATION = 30 minutes; // cap unless unlimitedMode
    uint256 public extensionPerTicket = 30 seconds;
    bool public unlimitedMode = false; // Unlimited mode removes 30m cap

    // Payment token (e.g., WBTC)
    IERC20 public immutable paymentToken;
    uint256 public ticketPrice;

    // Vault: receives 12%, and funds rounds by injection
    address public vault;

    // Fee: post distribution fee at 0.001% (10 ppm)
    uint256 public constant FEE_PPM = 10; // 10 / 1_000_000 = 0.001%
    address public feeRecipient;

    // Airdrop config
    uint32 public airdropWinnersCount = 5;

    // VRF-like randomness provider (authorized coordinator)
    address public vrfCoordinator; // callback sender check (should be VRF contract)
    IGoatVRF public goatVrf; // VRF contract to request randomness
    // requestId => roundId
    mapping(uint256 => uint256) public requestToRound;
    // roundId => requestId
    mapping(uint256 => uint256) public roundToRequest;

    // Default VRF params (can be overridden on request)
    uint256 public defaultCallbackGas = 120000;
    uint256 public defaultMaxAllowedGasPrice = 50 gwei;

    // EIP-712 authorizer for free ticket claim
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

    // ---- Rounds ----
    struct RoundMeta {
        uint64 startTime;
        uint64 endTime;
        uint256 pool; // total pool amount (includes ticket payments and vault injections) for this round
        uint256 totalTickets;
        address lastBuyer;
        bool settled;
        uint16 fundingRatioBps; // chosen ratio 500-1000 bps (5%-10%)
        address winner;
    }

    uint256 public currentRoundId;
    mapping(uint256 => RoundMeta) public rounds;
    mapping(uint256 => uint256) public roundRandomness; // set by vrfCoordinator (or fallback)

    // Participants and tickets per round
    mapping(uint256 => address[]) private roundParticipants;
    mapping(uint256 => mapping(address => bool)) private isParticipantInRound;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;
    mapping(uint256 => mapping(address => bool)) public usedFreeMint;

    // Last round summary fields for quick frontend access
    address public lastRoundWinner;
    uint256 public lastRoundTotalPool;
    uint16 public lastRoundFundingRatioBps;

    constructor(
        address _paymentToken,
        uint256 _ticketPrice,
        address _vault,
        uint256 _extensionPerTicket,
        bool _unlimitedMode,
        uint32 _airdropWinnersCount,
        address _authorizer
    ) Ownable(msg.sender) {
        require(_paymentToken != address(0), "TOKEN_ZERO");
        require(_vault != address(0), "VAULT_ZERO");
        paymentToken = IERC20(_paymentToken);
        ticketPrice = _ticketPrice;
        vault = _vault;
        extensionPerTicket = _extensionPerTicket == 0
            ? extensionPerTicket
            : _extensionPerTicket;
        unlimitedMode = _unlimitedMode;
        airdropWinnersCount = _airdropWinnersCount == 0
            ? airdropWinnersCount
            : _airdropWinnersCount;
        feeRecipient = msg.sender;
        authorizer = _authorizer;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("TimeTicket")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

        _startNextRound(0);
    }

    // ---- External user functions ----
    function buy(uint256 quantity) external nonReentrant {
        require(quantity > 0, "QTY_ZERO");
        RoundMeta storage rm = rounds[currentRoundId];
        require(!rm.settled, "ROUND_SETTLED");
        require(block.timestamp <= rm.endTime, "ROUND_ENDED");

        uint256 cost = ticketPrice * quantity;
        if (cost > 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), cost);
        }

        _afterTicketMint(msg.sender, quantity, cost);
    }

    function claimFreeTicket(
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        RoundMeta storage rm = rounds[currentRoundId];
        require(!rm.settled, "ROUND_SETTLED");
        require(block.timestamp <= rm.endTime, "ROUND_ENDED");
        require(block.timestamp <= deadline, "EXPIRED");
        require(!usedFreeMint[currentRoundId][msg.sender], "ALREADY_USED");
        require(authorizer != address(0), "NO_AUTH");

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, currentRoundId, msg.sender, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address signer = _recoverSigner(digest, signature);
        require(signer == authorizer, "BAD_SIG");

        usedFreeMint[currentRoundId][msg.sender] = true;

        _afterTicketMint(msg.sender, 1, 0);
        emit FreeTicketClaimed(currentRoundId, msg.sender);
    }

    function settle() external nonReentrant {
        RoundMeta storage rm = rounds[currentRoundId];
        require(!rm.settled, "ROUND_SETTLED");
        require(block.timestamp > rm.endTime, "ROUND_NOT_OVER");

        // 1) Determine and inject vault funding before distribution
        uint16 ratioBps = _getOrComputeFundingRatio(currentRoundId);
        rm.fundingRatioBps = ratioBps;

        uint256 desiredInjection = (rm.pool * ratioBps) / 10_000;
        uint256 injected = 0;
        if (desiredInjection > 0) {
            uint256 vaultAllowance = IERC20(paymentToken).allowance(
                vault,
                address(this)
            );
            uint256 vaultBalance = IERC20(paymentToken).balanceOf(vault);
            uint256 transferable = vaultAllowance < vaultBalance
                ? vaultAllowance
                : vaultBalance;
            if (transferable > 0) {
                injected = desiredInjection <= transferable
                    ? desiredInjection
                    : transferable;
                if (injected > 0) {
                    paymentToken.safeTransferFrom(
                        vault,
                        address(this),
                        injected
                    );
                    rm.pool += injected;
                }
            }
        }
        emit VaultFunded(currentRoundId, desiredInjection, injected, ratioBps);

        // 2) Apply fee 0.001%
        uint256 fee = (rm.pool * FEE_PPM) / 1_000_000;
        if (fee > 0 && feeRecipient != address(0)) {
            paymentToken.safeTransfer(feeRecipient, fee);
        }
        uint256 netPool = rm.pool - fee;

        // 3) Compute distributions
        uint256 winnerShare = (netPool * 48) / 100;
        uint256 dividendPool = (netPool * 20) / 100;
        uint256 airdropPool = (netPool * 10) / 100;
        uint256 teamShare = (netPool * 12) / 100;
        uint256 carryShare = (netPool * 10) / 100;

        address[] memory participants = roundParticipants[currentRoundId];
        uint256 participantCount = participants.length;

        // Track undistributed remainder to carry
        uint256 undistributed = 0;

        // Winner payout (48%)
        if (rm.lastBuyer != address(0) && winnerShare > 0) {
            paymentToken.safeTransfer(rm.lastBuyer, winnerShare);
            rm.winner = rm.lastBuyer;
        } else {
            undistributed += winnerShare;
        }

        // Team vault (12%)
        if (teamShare > 0 && vault != address(0)) {
            paymentToken.safeTransfer(vault, teamShare);
        } else {
            undistributed += teamShare;
        }

        // Dividend to all participants equally (20%)
        if (dividendPool > 0 && participantCount > 0) {
            uint256 perUser = dividendPool / participantCount;
            if (perUser > 0) {
                for (uint256 i = 0; i < participantCount; i++) {
                    paymentToken.safeTransfer(participants[i], perUser);
                }
                uint256 distributed = perUser * participantCount;
                if (dividendPool > distributed) {
                    undistributed += (dividendPool - distributed);
                }
            } else {
                // if too small to split
                undistributed += dividendPool;
            }
        } else {
            undistributed += dividendPool;
        }

        // Airdrop to random winners (10%)
        uint256 winnersCount = airdropWinnersCount;
        if (participantCount < winnersCount) {
            winnersCount = uint32(participantCount);
        }
        if (airdropPool > 0 && winnersCount > 0) {
            uint256 perWinner = airdropPool / winnersCount;
            if (perWinner > 0) {
                _payAirdrops(
                    participants,
                    winnersCount,
                    perWinner,
                    currentRoundId
                );
                uint256 distributed = perWinner * winnersCount;
                if (airdropPool > distributed) {
                    undistributed += (airdropPool - distributed);
                }
            } else {
                undistributed += airdropPool;
            }
        } else {
            undistributed += airdropPool;
        }

        // Carry and remainder stay in contract, seed next round
        uint256 carryPool = carryShare + undistributed;
        rm.settled = true;

        // Store last round summary
        lastRoundWinner = rm.winner;
        lastRoundTotalPool = rm.pool;
        lastRoundFundingRatioBps = rm.fundingRatioBps;

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
    }

    // ---- Owner/Admin ----
    function setVault(address newVault) external onlyOwner {
        require(newVault != address(0), "ZERO_ADDR");
        vault = newVault;
        emit ConfigUpdated("vault");
    }

    function setTicketPrice(uint256 newPrice) external onlyOwner {
        ticketPrice = newPrice;
        emit ConfigUpdated("ticketPrice");
    }

    function setAirdropWinnersCount(uint32 newCount) external onlyOwner {
        require(newCount <= 1000, "TOO_MANY");
        airdropWinnersCount = newCount;
        emit ConfigUpdated("airdropWinnersCount");
    }

    function setUnlimitedMode(bool enabled) external onlyOwner {
        unlimitedMode = enabled;
        emit ConfigUpdated("unlimitedMode");
    }

    function setExtensionPerTicket(uint256 newExtension) external onlyOwner {
        require(newExtension > 0 && newExtension <= 1 hours, "BAD_EXT");
        extensionPerTicket = newExtension;
        emit ConfigUpdated("extensionPerTicket");
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "ZERO_ADDR");
        feeRecipient = newRecipient;
        emit ConfigUpdated("feeRecipient");
    }

    function setAuthorizer(address newAuthorizer) external onlyOwner {
        authorizer = newAuthorizer;
        emit ConfigUpdated("authorizer");
    }

    function setVrfCoordinator(address newVrf) external onlyOwner {
        vrfCoordinator = newVrf;
        emit ConfigUpdated("vrfCoordinator");
    }

    function setGoatVrf(address newVrf) external onlyOwner {
        require(newVrf != address(0), "ZERO_ADDR");
        goatVrf = IGoatVRF(newVrf);
        vrfCoordinator = newVrf; // assume coordinator is the same contract that callbacks
        emit ConfigUpdated("goatVrf");
    }

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

    function ownerWithdraw(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        require(to != address(0), "ZERO_ADDR");
        IERC20(token).transfer(to, amount);
    }

    // ---- VRF randomness hook ----
    function receiveRandomness(uint256 requestId, uint256 randomWord) external {
        require(msg.sender == vrfCoordinator, "NOT_COORD");
        uint256 roundId = requestToRound[requestId];
        require(roundId != 0, "REQ_UNKNOWN");
        // allow setting only before settlement
        require(!rounds[roundId].settled, "ALREADY_SETTLED");
        roundRandomness[roundId] = randomWord;
    }

    function requestRandomnessForCurrentRound(
        uint256 deadline
    ) external onlyOwner returns (uint256 requestId) {
        require(address(goatVrf) != address(0), "VRF_NOT_SET");
        uint256 roundId = currentRoundId;
        require(roundToRequest[roundId] == 0, "ALREADY_REQ");
        // optional: don't request if already have randomness
        require(roundRandomness[roundId] == 0, "ALREADY_HAVE");

        // Approve fee in fee token
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

    function requestRandomnessForCurrentRoundAuto()
        external
        onlyOwner
        returns (uint256 requestId)
    {
        uint256 deadline = recommendDeadline();
        return this.requestRandomnessForCurrentRound(deadline);
    }

    function recommendDeadline() public view returns (uint256) {
        if (address(goatVrf) == address(0)) return block.timestamp + 5 minutes;
        address beaconAddr = goatVrf.beacon();
        if (beaconAddr == address(0)) return block.timestamp + 5 minutes;
        uint256 p = IDrandBeacon(beaconAddr).period();
        if (p == 0) return block.timestamp + 5 minutes;
        // aim 2 periods ahead
        return block.timestamp + 2 * p;
    }

    // ---- Views for frontend ----
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

    function getRemainingSeconds() external view returns (uint256) {
        RoundMeta storage rm = rounds[currentRoundId];
        if (block.timestamp >= rm.endTime) return 0;
        return rm.endTime - block.timestamp;
    }

    function getTicketPrice() external view returns (uint256) {
        return ticketPrice;
    }

    function getUserTicketsInCurrentRound(
        address user
    ) external view returns (uint256) {
        return ticketsOf[currentRoundId][user];
    }

    function getLastRoundSummary()
        external
        view
        returns (address winner, uint256 totalPool, uint16 fundingRatioBps)
    {
        return (lastRoundWinner, lastRoundTotalPool, lastRoundFundingRatioBps);
    }

    function getRoundParticipants(
        uint256 roundId
    ) external view returns (address[] memory) {
        return roundParticipants[roundId];
    }

    // ---- Internal helpers ----
    function _afterTicketMint(
        address buyer,
        uint256 quantity,
        uint256 paidAmount
    ) internal {
        RoundMeta storage rm = rounds[currentRoundId];

        // Time extension
        uint64 newEnd = rm.endTime + uint64(extensionPerTicket * quantity);
        if (!unlimitedMode) {
            uint64 maxEnd = rm.startTime + uint64(MAX_ROUND_DURATION);
            if (newEnd > maxEnd) newEnd = maxEnd;
        }
        rm.endTime = newEnd;

        // Pool and accounting
        rm.pool += paidAmount;
        rm.totalTickets += quantity;
        rm.lastBuyer = buyer;

        if (!isParticipantInRound[currentRoundId][buyer]) {
            isParticipantInRound[currentRoundId][buyer] = true;
            roundParticipants[currentRoundId].push(buyer);
        }
        ticketsOf[currentRoundId][buyer] += quantity;

        emit TicketPurchased(
            currentRoundId,
            buyer,
            quantity,
            paidAmount,
            newEnd
        );
    }

    function _startNextRound(uint256 carryPool) internal {
        ++currentRoundId;
        RoundMeta storage rm = rounds[currentRoundId];
        rm.startTime = uint64(block.timestamp);
        rm.endTime = uint64(block.timestamp + BASE_ROUND_DURATION);
        rm.pool = carryPool;
        emit RoundStarted(currentRoundId, rm.startTime, rm.endTime, carryPool);
    }

    function _getOrComputeFundingRatio(
        uint256 roundId
    ) internal view returns (uint16) {
        uint256 rnd = roundRandomness[roundId];
        require(rnd > 0, "NO_RANDOMNESS");
        uint16 ratio = uint16(500 + (rnd % 501)); // 5% - 10% inclusive
        return ratio;
    }

    function _payAirdrops(
        address[] memory participants,
        uint256 winnersCount,
        uint256 perWinner,
        uint256 roundId
    ) internal {
        uint256 participantCount = participants.length;
        if (participantCount == 0 || winnersCount == 0 || perWinner == 0)
            return;

        uint256 seed = roundRandomness[roundId];
        require(seed > 0, "NO_RANDOMNESS");

        // Reservoir-like selection of distinct winners using hashing. For simplicity, use a bitmap via mapping-in-memory approach.
        // Since we cannot have mappings in memory, we use a small loop with retries bounded by winnersCount * 5 to avoid DoS.
        bool[] memory selected = new bool[](participantCount);
        uint256 selectedCount = 0;
        uint256 tries = 0;
        while (selectedCount < winnersCount && tries < winnersCount * 10) {
            uint256 idx = uint256(keccak256(abi.encodePacked(seed, tries))) %
                participantCount;
            if (!selected[idx]) {
                selected[idx] = true;
                selectedCount++;
                paymentToken.safeTransfer(participants[idx], perWinner);
            }
            tries++;
        }
    }

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
