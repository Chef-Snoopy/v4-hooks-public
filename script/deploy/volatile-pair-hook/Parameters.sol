// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

struct DeployParameters {
    IPoolManager poolManager;
    bytes32 volatilePairHookProxySalt; // cached CREATE2 salt for the VolatilePairHook ERC1967 proxy (0 = mine at runtime)
    // cached CREATE2 salt for the VolatilePairHook implementation, mined so the implementation
    // address carries no hook-flag bits (0 = mine at runtime)
    bytes32 volatilePairHookImplementationSalt;
    // VolatilePairHook roles, baked into the proxy constructor args (and thus the mined hook
    // address); must be set for a chain before deploying, the deploy script reverts on zero
    address owner;
    address poolInitializer;
    address configManager;
}

/// @title Parameters
/// @notice Per-chain deployment parameters for the VolatilePairHook deploy script
contract Parameters {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);

    mapping(uint256 chainId => DeployParameters) public parameters;

    constructor() {
        // PoolManager addresses: https://docs.uniswap.org/contracts/v4/deployments
        parameters[ETHEREUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
            volatilePairHookProxySalt: bytes32(0),
            volatilePairHookImplementationSalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
            volatilePairHookProxySalt: bytes32(uint256(0x1938)),
            volatilePairHookImplementationSalt: bytes32(uint256(0x290d)),
            owner: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            poolInitializer: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            configManager: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95
        });
    }

    function getParameters(uint256 chainId) public view returns (DeployParameters memory params) {
        params = parameters[chainId];
        if (address(params.poolManager) == address(0)) {
            revert ParametersNotSetForChainId(chainId);
        }
    }
}
