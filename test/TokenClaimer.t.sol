// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {TokenClaimerUpgradeable} from "../src/TokenClaimer.sol";
import {TestToken} from "../src/TestToken.sol";
import {UpgradeableProxy} from "../src/UpgradeableProxy.sol";

contract TokenClaimerTest is Test {
    TokenClaimerUpgradeable public claimer;
    TestToken public token;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    address public user4 = address(0x5);
    address public nonWhitelisted = address(0x999);

    uint256 public constant INITIAL_SUPPLY = 1000000e18;

    // Test data arrays
    address[] public addresses;
    uint256[] public amounts;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy test token
        token = new TestToken();

        // Deploy claimer contract
        claimer = new TokenClaimerUpgradeable(address(token));
        UpgradeableProxy proxy = new UpgradeableProxy(
            address(claimer),
            owner,
            abi.encodeWithSelector(TokenClaimerUpgradeable.initialize.selector)
        );
        // claimer.initialize();
        claimer = TokenClaimerUpgradeable(address(proxy));

        // Set end time to far in the future to avoid claiming period issues
        claimer.setEndTime(block.timestamp + 365 days);

        // Transfer tokens to claimer contract
        token.transfer(address(claimer), INITIAL_SUPPLY);

        vm.stopPrank();

        // Setup test data
        addresses.push(user1);
        addresses.push(user2);
        addresses.push(user3);
        addresses.push(user4);

        amounts.push(100e18);
        amounts.push(200e18);
        amounts.push(300e18);
        amounts.push(400e18);
    }

    function testConstructor() public {
        assertEq(address(claimer.token()), address(token));
        assertEq(claimer.owner(), owner);
        assertEq(claimer.merkleRoot(), bytes32(0));
    }

    function testSetMerkleRoot() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TokenClaimerUpgradeable.MerkleRootSet(testRoot);
        claimer.setMerkleRoot(testRoot);

        assertEq(claimer.merkleRoot(), testRoot);
    }

    function testSetMerkleRootOnlyOwner() public {
        bytes32 testRoot = keccak256("test");

        vm.prank(user1);
        vm.expectRevert();
        claimer.setMerkleRoot(testRoot);
    }

    function testGenerateMerkleRoot() public {
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);

        // Root should not be zero for valid input
        assertNotEq(root, bytes32(0));
    }

    function testGenerateProof() public {
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Proof should not be empty for multiple addresses
        assertGt(proof.length, 0);
    }

    function testVerifyAddress() public {
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Valid proof should verify correctly
        bool isValid = claimer.verifyAddress(proof, root, user2, 200e18);
        assertTrue(isValid);

        // Invalid amount should fail verification
        isValid = claimer.verifyAddress(proof, root, user2, 999e18);
        assertFalse(isValid);
    }

    function testClaimSuccessful() public {
        // Setup merkle root
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Generate proof for user2
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Record initial balances
        uint256 initialUserBalance = token.balanceOf(user2);
        uint256 initialContractBalance = token.balanceOf(address(claimer));

        // Claim tokens
        vm.prank(user2);
        vm.expectEmit(true, true, true, true);
        emit TokenClaimerUpgradeable.Claimed(user2, user2, 200e18);
        claimer.claim(user2, 200e18, proof);

        // Check balances
        assertEq(token.balanceOf(user2), initialUserBalance + 200e18);
        assertEq(
            token.balanceOf(address(claimer)),
            initialContractBalance - 200e18
        );

        // Check claimed status
        assertTrue(claimer.hasClaimed(user2));
    }

    function testClaimToOtherAddress() public {
        // Setup merkle root
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Generate proof for user2
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Record initial balance
        uint256 initialRecipientBalance = token.balanceOf(nonWhitelisted);

        // Claim tokens to different address
        vm.prank(user2);
        claimer.claim(nonWhitelisted, 200e18, proof);

        // Check recipient balance
        assertEq(
            token.balanceOf(nonWhitelisted),
            initialRecipientBalance + 200e18
        );

        // Check claimed status is for recipient, not claimer
        assertTrue(claimer.hasClaimed(user2));
    }

    function testClaimAlreadyClaimed() public {
        // Setup merkle root
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Generate proof for user2
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // First claim
        vm.prank(user2);
        claimer.claim(user2, 200e18, proof);

        // Second claim should fail
        vm.prank(user2);
        vm.expectRevert("E08: Already claimed");
        claimer.claim(user2, 200e18, proof);
    }

    function testClaimInvalidProof() public {
        // Setup merkle root
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Generate valid proof for user2
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Try to claim with user1 using user2's proof
        vm.prank(user1);
        vm.expectRevert("E09: Not whitelisted");
        claimer.claim(user1, 200e18, proof);
    }

    function testClaimInvalidAmount() public {
        // Setup merkle root
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Generate proof for user2
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        // Try to claim with wrong amount
        vm.prank(user2);
        vm.expectRevert("E09: Not whitelisted");
        claimer.claim(user2, 999e18, proof);
    }

    function testWithdrawSuccessful() public {
        uint256 withdrawAmount = 100e18;
        uint256 initialOwnerBalance = token.balanceOf(owner);
        uint256 initialContractBalance = token.balanceOf(address(claimer));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TokenClaimerUpgradeable.Withdrawn(owner, withdrawAmount);
        claimer.withdraw(owner, withdrawAmount);

        assertEq(token.balanceOf(owner), initialOwnerBalance + withdrawAmount);
        assertEq(
            token.balanceOf(address(claimer)),
            initialContractBalance - withdrawAmount
        );
    }

    function testWithdrawOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        claimer.withdraw(user1, 100e18);
    }

    function testWithdrawInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert("E05: Invalid recipient address");
        claimer.withdraw(address(0), 100e18);
    }

    function testWithdrawZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("E06: Amount must be greater than zero");
        claimer.withdraw(owner, 0);
    }

    function testWithdrawInsufficientBalance() public {
        uint256 contractBalance = token.balanceOf(address(claimer));

        vm.prank(owner);
        vm.expectRevert("E10: Insufficient contract balance");
        claimer.withdraw(owner, contractBalance + 1);
    }

    function testClaimInvalidRecipient() public {
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        vm.prank(user2);
        vm.expectRevert("E05: Invalid recipient address");
        claimer.claim(address(0), 200e18, proof);
    }

    function testClaimZeroAmount() public {
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        vm.prank(user2);
        vm.expectRevert("E06: Amount must be greater than zero");
        claimer.claim(user2, 0, proof);
    }

    function testClaimMerkleRootNotSet() public {
        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        vm.prank(user2);
        vm.expectRevert("E07: Merkle root not set");
        claimer.claim(user2, 200e18, proof);
    }

    function testClaimInsufficientContractBalance() public {
        bytes32 root = claimer.generateMerkleRoot(addresses, amounts);
        vm.prank(owner);
        claimer.setMerkleRoot(root);

        // Withdraw most tokens first
        uint256 contractBalance = token.balanceOf(address(claimer));
        vm.prank(owner);
        claimer.withdraw(owner, contractBalance - 100e18);

        bytes32[] memory proof = claimer.generateProof(
            addresses,
            amounts,
            user2
        );

        vm.prank(user2);
        vm.expectRevert("E10: Insufficient contract balance");
        claimer.claim(user2, 200e18, proof);
    }
}
