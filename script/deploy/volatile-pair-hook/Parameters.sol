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
            // mined for 0x000022Ec4eBD6b12294396E852E4C3876b253Cc0 (prefix 0x000022, flags 0x3CC0)
            volatilePairHookProxySalt: 0x0000000000000000000000000000000000000000c7441c3a21254802cd8406f8,
            volatilePairHookImplementationSalt: bytes32(uint256(0x43b9)),
            // Uniswap Governance Timelock (admin: GovernorBravo 0x408ED6354d4973f66138C91495F2f2FCbd8724C3)
            owner: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC,
            poolInitializer: 0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27,
            configManager: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
            volatilePairHookProxySalt: bytes32(uint256(0x2d3)),
            volatilePairHookImplementationSalt: bytes32(uint256(0x26d2)),
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
