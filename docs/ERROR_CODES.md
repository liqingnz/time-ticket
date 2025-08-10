# TokenClaimer Error Codes

This document provides a comprehensive list of all error codes used in the TokenClaimer contract system. Each error has a unique code for precise identification and handling.

## Error Code Reference

| Error Code | Message                                           | Description                                      | When It Occurs                                                                                              |
| ---------- | ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `E01`      | `Array cannot be empty`                           | Input array is empty when it should contain data | - `generateMerkleRoot()` called with empty arrays<br>- `generateProof()` called with empty arrays           |
| `E02`      | `Addresses and amounts must have the same length` | Arrays have different lengths                    | - `generateMerkleRoot()` called with mismatched arrays<br>- `generateProof()` called with mismatched arrays |
| `E03`      | `Target address not found`                        | Target address not found in whitelist            | - `generateProof()` called for non-whitelisted address                                                      |
| `E04`      | `Claiming period has ended`                       | Current time is past the end time                | - `claim()` called after `endTime`                                                                          |
| `E05`      | `Invalid recipient address`                       | Zero address provided as recipient               | - `claim()` called with `address(0)` as recipient<br>- `withdraw()` called with `address(0)` as recipient   |
| `E06`      | `Amount must be greater than zero`                | Zero or negative amount provided                 | - `claim()` called with amount = 0<br>- `withdraw()` called with amount = 0                                 |
| `E07`      | `Merkle root not set`                             | No Merkle root has been configured               | - `claim()` called before `setMerkleRoot()`                                                                 |
| `E08`      | `Already claimed`                                 | User has already claimed their tokens            | - `claim()` called by user who already claimed                                                              |
| `E09`      | `Not whitelisted`                                 | User is not in the whitelist or proof is invalid | - `claim()` called with invalid proof<br>- `claim()` called for non-whitelisted address                     |
| `E10`      | `Insufficient contract balance`                   | Contract doesn't have enough tokens              | - `claim()` called for amount > contract balance<br>- `withdraw()` called for amount > contract balance     |
