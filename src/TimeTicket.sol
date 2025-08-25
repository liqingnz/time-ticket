// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGoatVRF, IRandomnessCallback} from "./interfaces/IGoatVrf.sol";

contract TimeTicketUnlimited is IRandomnessCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    uint256 public constant BASE_ROUND_DURATION = 15 minutes;
    uint256 public extensionPerTicket = 30 seconds;

    IERC20 public immutable paymentToken;
    uint256 public ticketPrice;
    address public vault;
    uint256 public constant FEE_PPM = 10; // 0.001%
    address public feeRecipient;
    uint32 public airdropWinnersCount = 5;

    address public vrfCoordinator;
    IGoatVRF public goatVrf;
    mapping(uint256 => uint256) public requestToRound;
    mapping(uint256 => uint256) public roundToRequest;
    uint256 public defaultCallbackGas = 120000;
    uint256 public defaultMaxAllowedGasPrice = 50 gwei;

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

    struct RoundMeta {
        uint64 startTime;
        uint64 endTime;
        uint256 pool;
        uint256 totalTickets;
        address lastBuyer;
        bool settled;
        uint16 fundingRatioBps;
        address winner;
    }

    uint256 public currentRoundId;
    mapping(uint256 => RoundMeta) public rounds;
    mapping(uint256 => uint256) public roundRandomness;
    mapping(uint256 => address[]) private roundParticipants;
    mapping(uint256 => mapping(address => bool)) private isParticipantInRound;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;
    mapping(uint256 => mapping(address => bool)) public usedFreeMint;

    address public lastRoundWinner;
    uint256 public lastRoundTotalPool;
    uint16 public lastRoundFundingRatioBps;

    constructor(
        address _paymentToken,
        uint256 _ticketPrice,
        address _vault,
        uint256 _extensionPerTicket,
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

    // TODO: make it payable, add max acceptable price
    function buy(uint256 quantity) external nonReentrant {
        require(tx.origin == msg.sender, "NOT_EOA");
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
        uint16 ratioBps = _getFundingRatio(currentRoundId);
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

        uint256 fee = (rm.pool * FEE_PPM) / 1_000_000;
        if (fee > 0 && feeRecipient != address(0)) {
            paymentToken.safeTransfer(feeRecipient, fee);
        }
        uint256 netPool = rm.pool - fee;

        uint256 winnerShare = (netPool * 48) / 100;
        uint256 dividendPool = (netPool * 20) / 100;
        uint256 airdropPool = (netPool * 10) / 100;
        uint256 teamShare = (netPool * 12) / 100;
        uint256 carryShare = (netPool * 10) / 100;

        address[] memory participants = roundParticipants[currentRoundId];
        uint256 participantCount = participants.length;
        uint256 undistributed = 0;

        if (rm.lastBuyer != address(0) && winnerShare > 0) {
            paymentToken.safeTransfer(rm.lastBuyer, winnerShare);
            rm.winner = rm.lastBuyer;
        } else {
            undistributed += winnerShare;
        }

        if (teamShare > 0 && vault != address(0)) {
            paymentToken.safeTransfer(vault, teamShare);
        } else {
            undistributed += teamShare;
        }

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
                undistributed += dividendPool;
            }
        } else {
            undistributed += dividendPool;
        }

        uint256 winnersCount = airdropWinnersCount;
        if (participantCount < winnersCount) {
            winnersCount = uint32(participantCount);
        }
        // TODO: pick random airdrop winners
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

        uint256 carryPool = carryShare + undistributed;
        rm.settled = true;
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
        vrfCoordinator = newVrf;
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

    function receiveRandomness(uint256 requestId, uint256 randomWord) external {
        require(msg.sender == vrfCoordinator, "NOT_COORD");
        uint256 roundId = requestToRound[requestId];
        require(roundId != 0, "REQ_UNKNOWN");
        require(!rounds[roundId].settled, "ALREADY_SETTLED");
        roundRandomness[roundId] = randomWord;
    }

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

    function requestRandomnessForCurrentRoundAuto()
        external
        onlyOwner
        returns (uint256 requestId)
    {
        uint256 deadline = block.timestamp + 10 minutes;
        return this.requestRandomnessForCurrentRound(deadline);
    }

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

    function _afterTicketMint(
        address buyer,
        uint256 quantity,
        uint256 paidAmount
    ) internal {
        RoundMeta storage rm = rounds[currentRoundId];
        uint64 newEnd = rm.endTime + uint64(extensionPerTicket * quantity);
        rm.endTime = newEnd;
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

    function _getFundingRatio(uint256 roundId) internal view returns (uint16) {
        uint256 rnd = roundRandomness[roundId];
        require(rnd > 0, "NO_RANDOMNESS");
        return uint16(500 + (rnd % 501));
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
