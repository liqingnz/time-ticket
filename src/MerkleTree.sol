// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

library MerkleTree {
    // Function to generate Merkle Root from an array of leaves
    function generateMerkleRoot(
        bytes32[] memory _leaves
    ) public pure returns (bytes32) {
        require(_leaves.length > 0, "Array cannot be empty");

        // If only one address, return its hash as root (including amount for consistency)
        if (_leaves.length == 1) {
            return _leaves[0];
        }

        // Build the Merkle Tree
        while (_leaves.length > 1) {
            bytes32[] memory tempLeaves = new bytes32[](
                (_leaves.length + 1) / 2
            );

            for (uint256 i = 0; i < _leaves.length; i += 2) {
                if (i + 1 < _leaves.length) {
                    // Pair exists, hash them together
                    tempLeaves[i / 2] = _hashPair(_leaves[i], _leaves[i + 1]);
                } else {
                    // Odd leaf out, promote it to next level
                    tempLeaves[i / 2] = _leaves[i];
                }
            }
            _leaves = tempLeaves;
        }

        return _leaves[0];
    }

    // Generate proof for a specific leaf
    function generateProof(
        bytes32[] memory _leaves,
        bytes32 _target
    ) public pure returns (bytes32[] memory) {
        require(_leaves.length > 0, "Array cannot be empty");

        uint256 targetIndex = type(uint256).max;

        for (uint256 i = 0; i < _leaves.length; i++) {
            if (_leaves[i] == _target) {
                targetIndex = i;
            }
        }
        require(targetIndex != type(uint256).max, "Target leaf not found");

        // Store proofs
        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory tempProof;

        // Build tree and collect proof
        while (_leaves.length > 1) {
            bytes32[] memory tempLeaves = new bytes32[](
                (_leaves.length + 1) / 2
            );
            uint256 newTargetIndex = 0;

            for (uint256 i = 0; i < _leaves.length; i += 2) {
                if (i + 1 < _leaves.length) {
                    // Pair exists
                    tempLeaves[i / 2] = _hashPair(_leaves[i], _leaves[i + 1]);

                    // If target is in this pair, add sibling to proof
                    if (i == (targetIndex / 2) * 2) {
                        tempProof = new bytes32[](proof.length + 1);
                        for (uint256 j = 0; j < proof.length; j++) {
                            tempProof[j] = proof[j];
                        }

                        // Determine which sibling to add based on target position
                        if (targetIndex % 2 == 0) {
                            // Target is left child (even index), add right sibling
                            tempProof[proof.length] = _leaves[i + 1];
                        } else {
                            // Target is right child (odd index), add left sibling
                            tempProof[proof.length] = _leaves[i];
                        }
                        proof = tempProof;
                        newTargetIndex = i / 2;
                    }
                } else {
                    // Odd leaf
                    tempLeaves[i / 2] = _leaves[i];
                    if (i == (targetIndex / 2) * 2) {
                        newTargetIndex = i / 2;
                    }
                }
            }
            _leaves = tempLeaves;
            targetIndex = newTargetIndex;
        }

        return proof;
    }

    // Function to verify if a leaf is in the Merkle Tree
    function verifyProof(
        bytes32[] memory _proof,
        bytes32 _root,
        bytes32 _target
    ) public pure returns (bool) {
        return MerkleProof.verify(_proof, _root, _target);
    }

    // Helper function to hash two nodes
    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        // Ensure a < b to maintain consistent ordering
        return
            _a < _b
                ? keccak256(abi.encodePacked(_a, _b))
                : keccak256(abi.encodePacked(_b, _a));
    }
}
