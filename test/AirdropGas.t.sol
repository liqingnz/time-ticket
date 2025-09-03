// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract AirdropSelector {
    // Old approach: rejection sampling with bool[] visited and try limit
    function selectOld(
        address[] memory participants,
        uint256 winnersCount,
        uint256 seed,
        address finalWinner
    ) public pure returns (address[] memory out) {
        uint256 n = participants.length;
        if (n == 0 || winnersCount == 0) return new address[](0);
        bool[] memory selected = new bool[](n);
        out = new address[](winnersCount);
        uint256 selectedCount = 0;
        uint256 tries = 0;
        while (selectedCount < winnersCount && tries < winnersCount * 10) {
            uint256 idx = uint256(keccak256(abi.encodePacked(seed, tries))) % n;
            if (!selected[idx] && participants[idx] != finalWinner) {
                selected[idx] = true;
                out[selectedCount++] = participants[idx];
            }
            unchecked {
                ++tries;
            }
        }
    }

    // New approach: partial Fisher–Yates, excluding finalWinner by index
    function selectNew(
        address[] memory participants,
        uint256 winnersCount,
        uint256 seed,
        address finalWinner
    ) public pure returns (address[] memory out) {
        uint256 n = participants.length;
        if (n == 0 || winnersCount == 0) return new address[](0);

        // Find final winner index if any, move to end
        int256 winnerIdx = -1;
        if (finalWinner != address(0)) {
            for (uint256 i = 0; i < n; i++) {
                if (participants[i] == finalWinner) {
                    winnerIdx = int256(i);
                    break;
                }
            }
        }
        uint256 upperBound = n;
        if (winnerIdx >= 0) {
            uint256 wi = uint256(winnerIdx);
            if (wi != n - 1) {
                address tmp = participants[n - 1];
                participants[n - 1] = participants[wi];
                participants[wi] = tmp;
            }
            upperBound = n - 1;
        }

        // Partial Fisher–Yates
        uint256 k = winnersCount;
        if (k > upperBound) k = upperBound;
        for (uint256 i = 0; i < k; i++) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 range = upperBound - i;
            uint256 j = i + (seed % range);
            if (j != i) {
                address t = participants[i];
                participants[i] = participants[j];
                participants[j] = t;
            }
        }

        out = new address[](k);
        for (uint256 m = 0; m < k; m++) {
            out[m] = participants[m];
        }
    }
}

contract AirdropGasTest is Test {
    AirdropSelector sel;

    function setUp() public {
        sel = new AirdropSelector();
    }

    function _makeParticipants(uint256 n) internal pure returns (address[] memory arr) {
        arr = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            arr[i] = address(uint160(i + 1));
        }
    }

    function _logGas(string memory tag, uint256 gasUsed, uint256 n, uint256 k) internal {
        emit log_named_uint(string.concat(tag, ":gas"), gasUsed);
        emit log_named_uint(string.concat(tag, ":n"), n);
        emit log_named_uint(string.concat(tag, ":k"), k);
    }

    function _bench(uint256 n, uint256 k) internal {
        address[] memory participants = _makeParticipants(n);
        address winner = participants[0];
        uint256 seed = uint256(keccak256(abi.encodePacked("seed")));

        // Old
        uint256 g0 = gasleft();
        address[] memory oldW = sel.selectOld(participants, k, seed, winner);
        uint256 g1 = gasleft();
        uint256 gasOld = g0 - g1;
        // New
        uint256 g2 = gasleft();
        address[] memory newW = sel.selectNew(participants, k, seed, winner);
        uint256 g3 = gasleft();
        uint256 gasNew = g2 - g3;

        // Sanity: new returns exactly k (unless k > n-1)
        uint256 expected = k;
        if (expected > n - 1) expected = n - 1;
        assertEq(newW.length, expected, "new not full");
        // Old may be <= k due to try limit; don't assert equality
        // Also ensure winner excluded in new
        for (uint256 i = 0; i < newW.length; i++) {
            assertTrue(newW[i] != winner, "winner included in new");
        }

        _logGas("old", gasOld, n, k);
        _logGas("new", gasNew, n, k);
    }

    function test_bench_small() public {
        _bench(50, 3);
        _bench(50, 10);
    }

    function test_bench_medium() public {
        _bench(200, 10);
        _bench(200, 50);
    }

    function test_bench_large() public {
        _bench(1000, 10);
        _bench(1000, 100);
    }
}

