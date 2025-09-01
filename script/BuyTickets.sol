// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimeTicketUpgradeable} from "../src/TimeTicket.sol";

contract BuyTickets is Script {
    address public buyer;

    function run() public {
        // Get environment variables
        uint256 buyerPrivateKey = vm.envUint("PRIVATE_KEY");
        address timeTicketAddress = vm.envAddress("TIMETICKET_ADDR");

        buyer = vm.createWallet(buyerPrivateKey).addr;

        console.log("=== TimeTicket Buy Operation ===");
        console.log("Buyer:", buyer);
        console.log("TimeTicket Contract:", timeTicketAddress);

        // Connect to the deployed TimeTicket contract
        TimeTicketUpgradeable timeTicket = TimeTicketUpgradeable(
            payable(timeTicketAddress)
        );

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
        uint256 quantity = 1; // Buy 5 tickets
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

        // Check buyer's current balance
        uint256 buyerBalance = buyer.balance;
        console.log("Buyer Balance (wei):", buyerBalance);
        console.log("Buyer Balance (ETH):", buyerBalance / 1e18);

        require(buyerBalance >= maxTotalCost, "Insufficient balance");

        // Get user's current tickets in this round
        uint256 currentTickets = timeTicket.getUserTicketsInCurrentRound(buyer);
        console.log("Buyer's Current Tickets:", currentTickets);

        vm.startBroadcast(buyerPrivateKey);

        console.log("\n--- Executing Buy Transaction ---");

        // Execute the buy transaction
        timeTicket.buy{value: maxTotalCost}(quantity, maxTotalCost, deadline);

        console.log("Buy transaction completed successfully!");

        vm.stopBroadcast();

        // Display state after buying
        console.log("\n--- State After Buy ---");
        uint256 newPrice = timeTicket.getTicketPrice();
        uint256 newRemainingTime = timeTicket.getRemainingSeconds();
        uint256 newTickets = timeTicket.getUserTicketsInCurrentRound(buyer);

        console.log("New Ticket Price (wei):", newPrice);
        console.log("New Ticket Price (ETH):", newPrice / 1e18);
        console.log("New Remaining Time (seconds):", newRemainingTime);
        console.log("Buyer's New Ticket Count:", newTickets);

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

    // Function to buy with custom parameters
    function buyCustom(
        uint256 quantity,
        uint256 slippagePercent,
        uint256 deadlineMinutes
    ) public {
        uint256 buyerPrivateKey = vm.envUint("PRIVATE_KEY");
        address timeTicketAddress = vm.envAddress("TIMETICKET_ADDR");

        buyer = vm.createWallet(buyerPrivateKey).addr;

        TimeTicketUpgradeable timeTicket = TimeTicketUpgradeable(
            payable(timeTicketAddress)
        );

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

        vm.startBroadcast(buyerPrivateKey);
        timeTicket.buy{value: maxTotalCost}(quantity, maxTotalCost, deadline);
        vm.stopBroadcast();

        console.log("Custom buy completed!");
    }
}
