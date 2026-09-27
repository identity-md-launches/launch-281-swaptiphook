// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {STIP} from "../src/STIP.sol";
import {SwapTipHook} from "../src/SwapTipHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../script/helpers/HookMiner.sol";

contract DeploymentTest is Test {
    function test_chainRestrictionsWithoutEnvironment() public {
        Deploy script = new Deploy();
        script.checkChain(31337, 0);
        script.checkChain(31337, 31337);
        script.checkChain(11155111, 11155111);
        vm.expectRevert("unsupported chain");
        script.checkChain(1, 0);
        vm.expectRevert("unexpected chain");
        script.checkChain(11155111, 31337);
        assertEq(script.SEPOLIA_POOL_MANAGER(), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    }

    function test_runtimeHasNoEscapeOpcodes() public {
        STIP token = new STIP();
        bytes memory code = abi.encodePacked(type(SwapTipHook).creationCode, abi.encode(address(0x1234)));
        (bytes32 salt,) = HookMiner.find(address(this), code);
        SwapTipHook hook = new SwapTipHook{salt: salt}(IPoolManager(address(0x1234)));
        assertClean(address(token).code);
        assertClean(address(hook).code);
    }

    function assertClean(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
