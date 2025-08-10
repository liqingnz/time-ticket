// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Utils, ERC1967Proxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

interface ITransparentUpgradeableProxy {
    /// @dev See {UUPSUpgradeable-upgradeToAndCall}
    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external payable;
}

contract UniProxy is ERC1967Proxy {
    // An immutable address for the admin to avoid unnecessary SLOADs before each call
    // at the expense of removing the ability to change the admin once it's set.
    // This is acceptable if the admin is always a ProxyAdmin instance or similar contract
    // with its own ability to transfer the permissions to another account.
    address private immutable _admin;

    /**
     * @dev The proxy caller is the current admin, and can't fallback to the proxy target.
     */
    error ProxyDeniedAdminAccess();

    /**
     * @dev Initializes an upgradeable proxy managed by an instance of a {ProxyAdmin} with an `initialOwner`,
     * backed by the implementation at `_logic`, and optionally initialized with `_data` as explained in
     * {ERC1967Proxy-constructor}.
     * @dev Warning: once _admin has been setup, it cannot be changed anymore. Use a ProxyAdmin for upgradeability.
     */
    constructor(
        address _logic,
        address _proxyAdmin,
        bytes memory _data
    ) payable ERC1967Proxy(_logic, _data) {
        // @dev if _proxyAdmin is not set, this contract will be self-upgradeable
        require(
            _proxyAdmin != address(0),
            "Proxy admin cannot be zero address"
        );
        _admin = _proxyAdmin;
        // Set the storage value and emit an event for ERC-1967 compatibility
        ERC1967Utils.changeAdmin(_proxyAdmin);
    }

    /**
     * @dev Returns the admin of this proxy.
     */
    function proxyAdmin() public view virtual returns (address) {
        return _admin;
    }

    /**
     * @dev If caller is the admin process the call internally, otherwise transparently fallback to the proxy behavior.
     */
    function _fallback() internal virtual override {
        if (msg.sender == _admin) {
            if (
                msg.sig !=
                ITransparentUpgradeableProxy.upgradeToAndCall.selector
            ) {
                revert ProxyDeniedAdminAccess();
            } else {
                _dispatchUpgradeToAndCall();
            }
        } else {
            super._fallback();
        }
    }

    /**
     * @dev Upgrade the implementation of the proxy. See {ERC1967Utils-upgradeToAndCall}.
     *
     * Requirements:
     *
     * - If `data` is empty, `msg.value` must be zero.
     */
    function _dispatchUpgradeToAndCall() private {
        (address newImplementation, bytes memory data) = abi.decode(
            msg.data[4:],
            (address, bytes)
        );
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }
}
