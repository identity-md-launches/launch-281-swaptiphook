// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapTipHook} from "../src/SwapTipHook.sol";
import {HookMiner} from "./helpers/HookMiner.sol";

/// @notice Key-free standalone hook rehearsal. Production token + hook launch belongs to the network factory.
contract Deploy is Script {
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function checkChain(uint256 chainId, uint256 expectedChainId) public pure {
        require(chainId == 31337 || chainId == 11155111, "unsupported chain");
        require(expectedChainId == 0 || expectedChainId == chainId, "unexpected chain");
    }

    function run() external returns (SwapTipHook hook) {
        checkChain(block.chainid, vm.envOr("EXPECTED_CHAIN_ID", uint256(0)));
        bytes memory code = abi.encodePacked(type(SwapTipHook).creationCode, abi.encode(SEPOLIA_POOL_MANAGER));
        (bytes32 salt, address predicted) = HookMiner.find(CREATE2_DEPLOYER, code);
        vm.startBroadcast();
        hook = new SwapTipHook{salt: salt}(IPoolManager(SEPOLIA_POOL_MANAGER));
        vm.stopBroadcast();
        require(address(hook) == predicted, "CREATE2 deployer mismatch");
    }
}
