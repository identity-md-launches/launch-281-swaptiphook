// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

library HookMiner {
    function find(address deployer, bytes memory initCode)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.SWAP_TIP)) return (salt, predicted);
        }
        revert("no hook salt found");
    }
}
