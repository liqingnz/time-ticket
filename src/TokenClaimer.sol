// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MerkleTree} from "./MerkleTree.sol";

contract TokenClaimerUpgradeable is OwnableUpgradeable {
    event MerkleRootSet(bytes32 merkleRoot);
    event EndTimeSet(uint256 endTime);
    event Claimed(address indexed from, address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    IERC20 public immutable token;

    bytes32 public merkleRoot;
    uint256 public endTime;
    mapping(address => bool) public hasClaimed;

    constructor(address _token) {
        token = IERC20(_token);
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init(msg.sender);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootSet(_merkleRoot);
    }

    function setEndTime(uint256 _endTime) external onlyOwner {
        endTime = _endTime;
        emit EndTimeSet(_endTime);
    }

    // Function to generate Merkle Root from an array of addresses
    function generateMerkleRoot(
        address[] memory _addresses,
        uint256[] memory _amounts
    ) external pure returns (bytes32) {
        require(_addresses.length > 0, "E01: Array cannot be empty");
        require(
            _addresses.length == _amounts.length,
            "E02: Addresses and amounts must have the same length"
        );

        // Convert addresses and amounts to leaf nodes by hashing them
        bytes32[] memory leaves = new bytes32[](_addresses.length);
        for (uint256 i = 0; i < _addresses.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(_addresses[i], _amounts[i]));
        }

        // Use library to generate merkle root
        return MerkleTree.generateMerkleRoot(leaves);
    }

    // Generate proof for a specific address
    function generateProof(
        address[] memory _addresses,
        uint256[] memory _amounts,
        address _target
    ) external pure returns (bytes32[] memory) {
        require(_addresses.length > 0, "E01: Array cannot be empty");
        require(
            _addresses.length == _amounts.length,
            "E02: Addresses and amounts must have the same length"
        );

        // Create initial leaves and find target leaf
        bytes32[] memory leaves = new bytes32[](_addresses.length);
        bytes32 targetLeaf;
        bool targetFound = false;

        for (uint256 i = 0; i < _addresses.length; i++) {
            leaves[i] = keccak256(abi.encodePacked(_addresses[i], _amounts[i]));
            if (_addresses[i] == _target) {
                targetLeaf = leaves[i];
                targetFound = true;
            }
        }
        require(targetFound, "E03: Target address not found");

        // Use library to generate proof
        return MerkleTree.generateProof(leaves, targetLeaf);
    }

    // Function to verify if an address is in the Merkle Tree
    function verifyAddress(
        bytes32[] memory _proof,
        bytes32 _root,
        address _addr,
        uint256 _amount
    ) public pure returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(_addr, _amount));
        return MerkleTree.verifyProof(_proof, _root, leaf);
    }

    // claim tokens for a specific address
    function claim(
        address _to,
        uint256 _amount,
        bytes32[] memory _proof
    ) external payable {
        require(block.timestamp < endTime, "E04: Claiming period has ended");
        require(_to != address(0), "E05: Invalid recipient address");
        require(_amount > 0, "E06: Amount must be greater than zero");
        require(merkleRoot != bytes32(0), "E07: Merkle root not set");
        require(hasClaimed[msg.sender] == false, "E08: Already claimed");
        require(
            verifyAddress(_proof, merkleRoot, msg.sender, _amount),
            "E09: Not whitelisted"
        );
        require(
            token.balanceOf(address(this)) >= _amount,
            "E10: Insufficient contract balance"
        );

        hasClaimed[msg.sender] = true;
        token.transfer(_to, _amount);
        emit Claimed(msg.sender, _to, _amount);
    }

    // withdraw tokens for the owner
    function withdraw(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "E05: Invalid recipient address");
        require(_amount > 0, "E06: Amount must be greater than zero");
        require(
            token.balanceOf(address(this)) >= _amount,
            "E10: Insufficient contract balance"
        );

        token.transfer(_to, _amount);
        emit Withdrawn(_to, _amount);
    }
}
