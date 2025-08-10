// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {MerkleTree} from "../src/MerkleTree.sol";

contract MerkleTreeTest is Test {
    using MerkleTree for bytes32[];

    function testGenerateMerkleRootSingleLeaf() public {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("test");

        bytes32 root = leaves.generateMerkleRoot();
        assertEq(root, leaves[0]);
    }

    function testGenerateMerkleRootTwoLeaves() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32 root = leaves.generateMerkleRoot();

        // Root should be hash of the two leaves
        bytes32 expectedRoot = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));

        assertEq(root, expectedRoot);
    }

    function testGenerateMerkleRootFourLeaves() public {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");
        leaves[2] = keccak256("leaf3");
        leaves[3] = keccak256("leaf4");

        bytes32 root = leaves.generateMerkleRoot();

        // Root should not be zero
        assertNotEq(root, bytes32(0));
    }

    function testGenerateMerkleRootOddLeaves() public {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");
        leaves[2] = keccak256("leaf3");

        bytes32 root = leaves.generateMerkleRoot();

        // Root should not be zero
        assertNotEq(root, bytes32(0));
    }

    function testGenerateMerkleRootEmptyArray() public {
        bytes32[] memory leaves = new bytes32[](0);

        vm.expectRevert("Array cannot be empty");
        MerkleTree.generateMerkleRoot(leaves);
    }

    function testGenerateProofSingleLeaf() public {
        bytes32[] memory leaves = new bytes32[](1);
        bytes32 target = keccak256("test");
        leaves[0] = target;

        bytes32[] memory proof = leaves.generateProof(target);

        // Proof should be empty for single leaf
        assertEq(proof.length, 0);
    }

    function testGenerateProofTwoLeaves() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32[] memory proof = leaves.generateProof(leaves[0]);

        // Proof should contain one element (the sibling)
        assertEq(proof.length, 1);
        assertEq(proof[0], leaves[1]);
    }

    function testGenerateProofFourLeaves() public {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");
        leaves[2] = keccak256("leaf3");
        leaves[3] = keccak256("leaf4");

        bytes32[] memory proof = leaves.generateProof(leaves[0]);

        // For 4 leaves, proof should have 2 elements
        assertEq(proof.length, 2);
    }

    function testGenerateProofTargetNotFound() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32 nonExistentTarget = keccak256("nonexistent");

        vm.expectRevert("Target leaf not found");
        MerkleTree.generateProof(leaves, nonExistentTarget);
    }

    function testGenerateProofEmptyArray() public {
        bytes32[] memory leaves = new bytes32[](0);
        bytes32 target = keccak256("test");

        vm.expectRevert("Array cannot be empty");
        MerkleTree.generateProof(leaves, target);
    }

    function testVerifyProofValidSingleLeaf() public {
        bytes32[] memory leaves = new bytes32[](1);
        bytes32 target = keccak256("test");
        leaves[0] = target;

        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(target);

        bool isValid = MerkleTree.verifyProof(proof, root, target);
        assertTrue(isValid);
    }

    function testVerifyProofValidTwoLeaves() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(leaves[0]);

        bool isValid = MerkleTree.verifyProof(proof, root, leaves[0]);
        assertTrue(isValid);
    }

    function testVerifyProofValidFourLeaves() public {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");
        leaves[2] = keccak256("leaf3");
        leaves[3] = keccak256("leaf4");

        bytes32 root = leaves.generateMerkleRoot();

        // Test all leaves
        for (uint i = 0; i < 4; i++) {
            bytes32[] memory proof = leaves.generateProof(leaves[i]);
            bool isValid = MerkleTree.verifyProof(proof, root, leaves[i]);
            assertTrue(isValid);
        }
    }

    function testVerifyProofInvalidProof() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32 root = leaves.generateMerkleRoot();

        // Create invalid proof
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = keccak256("invalid");

        bool isValid = MerkleTree.verifyProof(invalidProof, root, leaves[0]);
        assertFalse(isValid);
    }

    function testVerifyProofInvalidRoot() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf1");
        leaves[1] = keccak256("leaf2");

        bytes32[] memory proof = leaves.generateProof(leaves[0]);
        bytes32 invalidRoot = keccak256("invalidroot");

        bool isValid = MerkleTree.verifyProof(proof, invalidRoot, leaves[0]);
        assertFalse(isValid);
    }

    function testConsistencyAcrossDifferentSizes() public {
        // Test that merkle trees are consistent across different sizes
        for (uint size = 1; size <= 8; size++) {
            bytes32[] memory leaves = new bytes32[](size);

            for (uint i = 0; i < size; i++) {
                leaves[i] = keccak256(abi.encodePacked("leaf", i));
            }

            bytes32 root = leaves.generateMerkleRoot();

            // Verify all leaves
            for (uint i = 0; i < size; i++) {
                bytes32[] memory proof = leaves.generateProof(leaves[i]);
                bool isValid = MerkleTree.verifyProof(proof, root, leaves[i]);
                assertTrue(isValid, "Proof should be valid for all leaves");
            }
        }
    }

    function testLargeTree() public {
        // Test with 16 leaves
        bytes32[] memory leaves = new bytes32[](16);

        for (uint i = 0; i < 16; i++) {
            leaves[i] = keccak256(abi.encodePacked("leaf", i));
        }

        bytes32 root = leaves.generateMerkleRoot();

        // Test a few random leaves
        uint[] memory testIndices = new uint[](4);
        testIndices[0] = 0;
        testIndices[1] = 5;
        testIndices[2] = 10;
        testIndices[3] = 15;

        for (uint i = 0; i < testIndices.length; i++) {
            uint index = testIndices[i];
            bytes32[] memory proof = leaves.generateProof(leaves[index]);
            bool isValid = MerkleTree.verifyProof(proof, root, leaves[index]);
            assertTrue(isValid);
        }
    }
}
