// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileHook} from "../../src/volatile/VolatileHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// A next version shaped the way a real V2 must be: inherited storage untouched, new state in its own appended
/// ERC-7201 namespace. See docs/technical/UpgradeRunbook.md.
contract VolatileHookV2Mock is VolatileHook {
    /// @custom:storage-location erc7201:uniswap.storage.VolatileHookV2Mock
    struct VolatileHookV2MockStorage {
        uint256 newValue;
    }

    /// keccak256(abi.encode(uint256(keccak256("uniswap.storage.VolatileHookV2Mock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_MOCK_STORAGE_LOCATION =
        0xe90d654d9eef4dc3b11d9e617b4016f4cccbc882e48d96738aa44c0d8bd8df00;

    constructor(IPoolManager _manager) VolatileHook(_manager) {}

    function _getV2MockStorage() private pure returns (VolatileHookV2MockStorage storage $) {
        assembly ("memory-safe") {
            $.slot := V2_MOCK_STORAGE_LOCATION
        }
    }

    /// Initializes only the state this version adds; V1's initializers already ran in the proxy.
    function initializeV2(uint256 _newValue) external reinitializer(2) {
        _getV2MockStorage().newValue = _newValue;
    }

    function newValue() external view returns (uint256) {
        return _getV2MockStorage().newValue;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
