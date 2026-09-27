// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {STIP} from "../../src/STIP.sol";
import {SwapTipHook} from "../../src/SwapTipHook.sol";
import {HookMiner} from "../../script/helpers/HookMiner.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    STIP internal token;
    SwapTipHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    address internal constant RECIPIENT = address(0xcafe);
    uint160 internal constant Q96 = 79228162514264337593543950336;

    function deployCore() internal {
        manager = new PoolManager(address(this));
        token = new STIP();
        bytes memory code = abi.encodePacked(type(SwapTipHook).creationCode, abi.encode(manager));
        (bytes32 salt, address predicted) = HookMiner.find(address(this), code);
        hook = new SwapTipHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        vm.deal(address(this), 10_000_000 ether);
    }

    function seedBalanced() internal {
        manager.initialize(key, Q96);
        liquidityRouter.modifyLiquidity{value: 2_000_000 ether}(
            key, ModifyLiquidityParams(-120000, 120000, 1_000_000 ether, bytes32(0)), ""
        );
    }

    function paramsFor(uint8 mode, uint256 amount) internal pure returns (SwapParams memory) {
        bool buy = mode < 2;
        bool exactIn = mode % 2 == 0;
        return SwapParams(
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function swap(uint8 mode, uint256 amount, bytes memory data) internal returns (BalanceDelta) {
        return router.swap{value: mode < 2 ? amount * 3 + 1 ether : 0}(
            key, paramsFor(mode, amount), PoolSwapTest.TestSettings(false, false), data
        );
    }

    function abs128(int128 amount) internal pure returns (uint256) {
        return uint256(amount < 0 ? -int256(amount) : int256(amount));
    }

    function assertClaims(uint256 expected) internal view {
        assertEq(manager.balanceOf(address(hook), 0), expected);
        assertEq(address(hook).balance, 0);
    }

    receive() external payable {}
}
