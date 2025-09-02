// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimeTicketUpgradeable} from "../src/TimeTicket.sol";

contract GameOperations is Script {
    address public operator;
    TimeTicketUpgradeable public timeTicket;
    uint256 public operatorPrivateKey;

    function setUp() public {
        // Get environment variables
        operatorPrivateKey = vm.envUint("PRIVATE_KEY");
        address timeTicketAddress = vm.envAddress("TIMETICKET_ADDR");

        operator = vm.createWallet(operatorPrivateKey).addr;
        timeTicket = TimeTicketUpgradeable(payable(timeTicketAddress));

        console.log("=== TimeTicket Game Operations ===");
        console.log("Operator:", operator);
        console.log("TimeTicket Contract:", timeTicketAddress);
    }

    function run() public {
        // Default action: buy tickets (can be changed by calling specific functions)
        // buyTickets();
        // requestRandomness();
        settleRound();
    }

    /// @notice Buy tickets with hardcoded parameters
    function buyTickets() public {
        // Display current state before buying
        console.log("\n--- Current State ---");
        uint256 currentPrice = timeTicket.getTicketPrice();
        uint256 remainingTime = timeTicket.getRemainingSeconds();
        uint256 currentRoundId = timeTicket.currentRoundId();

        console.log("Current Round ID:", currentRoundId);
        console.log("Current Ticket Price (wei):", currentPrice);
        console.log("Current Ticket Price (ETH):", currentPrice / 1e18);
        console.log("Remaining Time (seconds):", remainingTime);

        // Get current round data
        (
            uint64 startTime,
            uint64 endTime,
            uint256 totalPool,
            uint256 totalParticipants,
            uint256 totalTickets,
            address lastBuyer
        ) = timeTicket.getCurrentRoundData();

        console.log("Round Start Time:", startTime);
        console.log("Round End Time:", endTime);
        console.log("Total Pool (wei):", totalPool);
        console.log("Total Pool (ETH):", totalPool / 1e18);
        console.log("Total Participants:", totalParticipants);
        console.log("Total Tickets:", totalTickets);
        console.log("Last Buyer:", lastBuyer);

        // Hardcoded buy parameters
        uint256 quantity = 1; // Buy 1 ticket
        uint256 totalCost = currentPrice * quantity;
        uint256 maxTotalCost = totalCost + ((totalCost * 10) / 100); // 10% slippage tolerance
        uint256 deadline = block.timestamp + 10 minutes; // 10 minutes from now

        console.log("\n--- Buy Parameters ---");
        console.log("Quantity:", quantity);
        console.log("Expected Total Cost (wei):", totalCost);
        console.log("Expected Total Cost (ETH):", totalCost / 1e18);
        console.log("Max Total Cost (wei):", maxTotalCost);
        console.log("Max Total Cost (ETH):", maxTotalCost / 1e18);
        console.log("Deadline:", deadline);

        // Check operator's current balance
        uint256 operatorBalance = operator.balance;
        console.log("Operator Balance (wei):", operatorBalance);
        console.log("Operator Balance (ETH):", operatorBalance / 1e18);

        require(operatorBalance >= maxTotalCost, "Insufficient balance");

        // Get user's current tickets in this round
        uint256 currentTickets = timeTicket.getUserTicketsInCurrentRound(
            operator
        );
        console.log("Operator's Current Tickets:", currentTickets);

        vm.startBroadcast(operatorPrivateKey);

        console.log("\n--- Executing Buy Transaction ---");

        // Execute the buy transaction
        timeTicket.buy{value: maxTotalCost}(quantity, maxTotalCost, deadline);

        console.log("Buy transaction completed successfully!");

        vm.stopBroadcast();

        // Display state after buying
        console.log("\n--- State After Buy ---");
        uint256 newPrice = timeTicket.getTicketPrice();
        uint256 newRemainingTime = timeTicket.getRemainingSeconds();
        uint256 newTickets = timeTicket.getUserTicketsInCurrentRound(operator);

        console.log("New Ticket Price (wei):", newPrice);
        console.log("New Ticket Price (ETH):", newPrice / 1e18);
        console.log("New Remaining Time (seconds):", newRemainingTime);
        console.log("Operator's New Ticket Count:", newTickets);

        // Get updated round data
        (
            ,
            uint64 newEndTime,
            uint256 newTotalPool,
            uint256 newTotalParticipants,
            uint256 newTotalTickets,
            address newLastBuyer
        ) = timeTicket.getCurrentRoundData();

        console.log("New Round End Time:", newEndTime);
        console.log("New Total Pool (wei):", newTotalPool);
        console.log("New Total Pool (ETH):", newTotalPool / 1e18);
        console.log("New Total Participants:", newTotalParticipants);
        console.log("New Total Tickets:", newTotalTickets);
        console.log("New Last Buyer:", newLastBuyer);
    }

    /// @notice Request randomness for the current round (owner only)
    function requestRandomness() public {
        uint256 currentRoundId = timeTicket.currentRoundId();
        console.log("\n=== Request Randomness ===");
        console.log("Current Round ID:", currentRoundId);
        console.log("Operator:", operator);

        // Check if randomness already requested
        uint256 existingRequest = timeTicket.roundToRequest(currentRoundId);
        if (existingRequest != 0) {
            console.log(
                "Randomness already requested for round:",
                currentRoundId
            );
            console.log("Request ID:", existingRequest);
            return;
        }

        // Check if randomness already available
        uint256 existingRandomness = timeTicket.roundRandomness(currentRoundId);
        if (existingRandomness != 0) {
            console.log(
                "Randomness already available for round:",
                currentRoundId
            );
            console.log("Randomness:", existingRandomness);
            return;
        }

        vm.startBroadcast(operatorPrivateKey);

        console.log("Requesting randomness for current round...");

        try
            timeTicket.requestRandomnessForCurrentRound(
                block.timestamp + 10 minutes
            )
        returns (uint256 requestId) {
            console.log("Randomness requested successfully!");
            console.log("Request ID:", requestId);
        } catch Error(string memory reason) {
            console.log("Failed to request randomness:", reason);
        } catch {
            console.log("Failed to request randomness: Unknown error");
        }

        vm.stopBroadcast();
    }

    /// @notice Settle the current round
    function settleRound() public {
        uint256 currentRoundId = timeTicket.currentRoundId();
        console.log("\n=== Settle Round ===");
        console.log("Current Round ID:", currentRoundId);

        // Get current round info
        (
            uint64 startTime,
            uint64 endTime,
            uint256 totalPool,
            uint256 totalParticipants,
            uint256 totalTickets,
            address lastBuyer
        ) = timeTicket.getCurrentRoundData();

        console.log("Round End Time:", endTime);
        console.log("Current Time:", block.timestamp);
        console.log("Total Pool (ETH):", totalPool / 1e18);
        console.log("Total Participants:", totalParticipants);
        console.log("Total Tickets:", totalTickets);
        console.log("Last Buyer (Winner):", lastBuyer);

        // Check if round is ready to settle
        if (block.timestamp <= endTime) {
            uint256 remainingTime = endTime - block.timestamp;
            console.log(
                "Round not yet expired. Remaining time:",
                remainingTime,
                "seconds"
            );
            return;
        }

        // Check if randomness is available
        uint256 randomness = timeTicket.roundRandomness(currentRoundId);
        if (randomness == 0) {
            console.log("No randomness available for settlement");
            console.log("Request randomness first using requestRandomness()");
            return;
        }

        console.log("Randomness available:", randomness);

        // Check if already settled
        (, , , , , bool settled, , , ) = timeTicket.rounds(currentRoundId);
        if (settled) {
            console.log("Round already settled");
            return;
        }

        vm.startBroadcast(operatorPrivateKey);

        console.log("Settling round...");

        try timeTicket.settle() {
            console.log("Round settled successfully!");
        } catch Error(string memory reason) {
            console.log("Failed to settle round:", reason);
        } catch {
            console.log("Failed to settle round: Unknown error");
        }

        vm.stopBroadcast();

        // Display settlement results
        console.log("\n--- Settlement Results ---");

        // Get updated round info
        (
            ,
            ,
            ,
            ,
            ,
            bool newSettled,
            uint16 fundingRatio,
            address winner,
            uint256 unclaimed
        ) = timeTicket.rounds(currentRoundId);

        if (newSettled) {
            console.log("Round successfully settled!");
            console.log("Winner:", winner);
            console.log("Funding Ratio (BPS):", fundingRatio);
            console.log("Unclaimed Amount (ETH):", unclaimed / 1e18);

            // Check reward amounts
            uint256 winnerShare = timeTicket.winnerShareOfRound(currentRoundId);
            uint256 dividendPerParticipant = timeTicket.dividendPerParticipant(
                currentRoundId
            );
            uint256 airdropPerWinner = timeTicket.airdropPerWinner(
                currentRoundId
            );

            console.log("Winner Share (ETH):", winnerShare / 1e18);
            console.log(
                "Dividend Per Participant (ETH):",
                dividendPerParticipant / 1e18
            );
            console.log("Airdrop Per Winner (ETH):", airdropPerWinner / 1e18);

            // Show new round
            uint256 newRoundId = timeTicket.currentRoundId();
            console.log("New Round Started:", newRoundId);
        }
    }

    /// @notice Buy tickets with custom parameters
    function buyCustom(
        uint256 quantity,
        uint256 slippagePercent,
        uint256 deadlineMinutes
    ) public {
        uint256 currentPrice = timeTicket.getTicketPrice();
        uint256 totalCost = currentPrice * quantity;
        uint256 maxTotalCost = totalCost +
            ((totalCost * slippagePercent) / 100);
        uint256 deadline = block.timestamp + (deadlineMinutes * 1 minutes);

        console.log("=== Custom Buy ===");
        console.log("Quantity:", quantity);
        console.log("Slippage:", slippagePercent, "%");
        console.log("Deadline (minutes):", deadlineMinutes);
        console.log("Max Total Cost (ETH):", maxTotalCost / 1e18);

        vm.startBroadcast(operatorPrivateKey);
        timeTicket.buy{value: maxTotalCost}(quantity, maxTotalCost, deadline);
        vm.stopBroadcast();

        console.log("Custom buy completed!");
    }

    /// @notice Check claimable rewards for the operator
    function checkRewards() public view {
        uint256 currentRoundId = timeTicket.currentRoundId();
        console.log("\n=== Claimable Rewards Check ===");
        console.log("Operator:", operator);

        // Check recent settled rounds
        for (uint256 roundId = 1; roundId < currentRoundId; roundId++) {
            (, , , , , bool settled, , address winner, ) = timeTicket.rounds(
                roundId
            );

            if (!settled) continue;

            console.log("\n--- Round", roundId, "---");

            // Check winner reward
            if (winner == operator && !timeTicket.claimedWinner(roundId)) {
                uint256 winnerAmount = timeTicket.winnerShareOfRound(roundId);
                console.log("Winner Reward (ETH):", winnerAmount / 1e18);
            }

            // Check dividend reward
            if (
                timeTicket.ticketsOf(roundId, operator) > 0 &&
                !timeTicket.claimedDividend(roundId, operator)
            ) {
                uint256 dividendAmount = timeTicket.dividendPerParticipant(
                    roundId
                );
                console.log("Dividend Reward (ETH):", dividendAmount / 1e18);
            }

            // Check airdrop reward
            if (
                timeTicket.isAirdropWinner(roundId, operator) &&
                !timeTicket.claimedAirdrop(roundId, operator)
            ) {
                uint256 airdropAmount = timeTicket.airdropPerWinner(roundId);
                console.log("Airdrop Reward (ETH):", airdropAmount / 1e18);
            }
        }
    }

    /// @notice Claim all available rewards for the operator
    function claimRewards() public {
        uint256 currentRoundId = timeTicket.currentRoundId();
        console.log("\n=== Claim Rewards ===");
        console.log("Operator:", operator);

        vm.startBroadcast(operatorPrivateKey);

        // Check and claim from recent settled rounds
        for (uint256 roundId = 1; roundId < currentRoundId; roundId++) {
            (, , , , , bool settled, , address winner, ) = timeTicket.rounds(
                roundId
            );

            if (!settled) continue;

            // Prepare reward types array
            TimeTicketUpgradeable.RewardType[]
                memory rewardTypes = new TimeTicketUpgradeable.RewardType[](3);
            uint256 rewardCount = 0;

            // Check winner reward
            if (winner == operator && !timeTicket.claimedWinner(roundId)) {
                rewardTypes[rewardCount] = TimeTicketUpgradeable
                    .RewardType
                    .Winner;
                rewardCount++;
            }

            // Check dividend reward
            if (
                timeTicket.ticketsOf(roundId, operator) > 0 &&
                !timeTicket.claimedDividend(roundId, operator)
            ) {
                rewardTypes[rewardCount] = TimeTicketUpgradeable
                    .RewardType
                    .Dividend;
                rewardCount++;
            }

            // Check airdrop reward
            if (
                timeTicket.isAirdropWinner(roundId, operator) &&
                !timeTicket.claimedAirdrop(roundId, operator)
            ) {
                rewardTypes[rewardCount] = TimeTicketUpgradeable
                    .RewardType
                    .Airdrop;
                rewardCount++;
            }

            // Claim if any rewards available
            if (rewardCount > 0) {
                // Resize array to actual reward count
                TimeTicketUpgradeable.RewardType[]
                    memory actualRewards = new TimeTicketUpgradeable.RewardType[](
                        rewardCount
                    );
                for (uint256 i = 0; i < rewardCount; i++) {
                    actualRewards[i] = rewardTypes[i];
                }

                try timeTicket.claim(roundId, actualRewards) {
                    console.log("Claimed rewards for round:", roundId);
                } catch Error(string memory reason) {
                    console.log(
                        "Failed to claim rewards for round",
                        roundId,
                        ":",
                        reason
                    );
                }
            }
        }

        vm.stopBroadcast();

        console.log("Claim process completed!");
    }
}
