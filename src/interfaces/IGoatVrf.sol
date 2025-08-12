// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRandomnessCallback {
    function receiveRandomness(uint256 requestId, uint256 randomness) external;
}

interface IDrandBeacon {
    function period() external view returns (uint256);
}

interface IGoatVRF {
    function calculateFee(uint256 gas) external view returns (uint256 totalFee);

    function calculateFeeWithGasPrice(
        uint256 gas,
        uint256 gasPrice
    ) external view returns (uint256 totalFee);

    function getNewRandom(
        uint256 deadline,
        uint256 maxAllowedGasPrice,
        uint256 callbackGas
    ) external returns (uint256 requestId);

    function cancelRequest(uint256 requestId) external;

    function beacon() external view returns (address beaconAddr);

    function feeToken() external view returns (address tokenAddr);
}
