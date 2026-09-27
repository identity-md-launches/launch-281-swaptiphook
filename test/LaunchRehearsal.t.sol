// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {STIP} from "../src/STIP.sol";
import {SwapTipHook} from "../src/SwapTipHook.sol";
import {HookMiner} from "../script/helpers/HookMiner.sol";

/// @dev Offline stand-in for the deployment/initialize/seed sequence, not production factory source.
contract LaunchFactoryRehearsal is IUnlockCallback {
    IPoolManager public immutable manager;
    STIP public token;
    SwapTipHook public hook;
    uint256 public supplyReceived;
    uint256 public seedTokens;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 salt, uint160 price, int24 lower, int24 upper, uint128 liquidity)
        external
        returns (PoolKey memory key)
    {
        require(address(token) == address(0), "already launched");
        token = new STIP();
        supplyReceived = token.balanceOf(address(this));
        require(supplyReceived == 1_000_000_000 ether, "supply mismatch");
        hook = new SwapTipHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(key, price);
        manager.unlock(
            abi.encode(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)))
        );
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, ModifyLiquidityParams memory params) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be STIP only");
        seedTokens = uint256(-int256(delta.amount1()));
        manager.sync(key.currency1);
        token.transfer(address(manager), seedTokens);
        manager.settle();
        return "";
    }
}

contract LaunchRehearsalTest is Test {
    using StateLibrary for IPoolManager;

    // Proposed rehearsal parameters: supplied workflow contains no numeric manifest price/seed.
    // The manifest producer must adopt these or have this fixture updated to its final values.
    int24 internal constant INITIAL_TICK = 184200;
    int24 internal constant LOWER_TICK = -887220;
    uint256 internal constant SEED_BUDGET = 900_000_000 ether;
    address internal constant RECIPIENT = address(0xcafe);

    PoolManager internal manager;
    LaunchFactoryRehearsal internal factory;
    PoolSwapTest internal router;
    PoolKey internal key;
    uint160 internal initialPrice;
    uint128 internal seedLiquidity;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new LaunchFactoryRehearsal(manager);
        router = new PoolSwapTest(manager);
        initialPrice = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        seedLiquidity = uint128(
            FullMath.mulDiv(SEED_BUDGET, 1 << 96, initialPrice - TickMath.getSqrtPriceAtTick(LOWER_TICK))
        );
        bytes memory code = abi.encodePacked(type(SwapTipHook).creationCode, abi.encode(manager));
        (bytes32 salt, address predicted) = HookMiner.find(address(factory), code);
        key = factory.launch(salt, initialPrice, LOWER_TICK, INITIAL_TICK, seedLiquidity);
        assertEq(address(factory.hook()), predicted);
        factory.token().approve(address(router), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function test_factoryMintsInitializesAndSeedsOnlySTIP() public view {
        assertEq(factory.supplyReceived(), 1_000_000_000 ether);
        assertLe(factory.seedTokens(), SEED_BUDGET);
        assertGe(factory.seedTokens(), SEED_BUDGET - 10000);
        assertEq(factory.token().balanceOf(address(manager)), factory.seedTokens());
        assertEq(factory.token().balanceOf(address(this)), 1_000_000_000 ether - factory.seedTokens());
        assertEq(address(manager).balance, 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, initialPrice);
        (uint128 position,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(factory), LOWER_TICK, INITIAL_TICK, bytes32(0));
        assertEq(position, seedLiquidity);
    }

    function test_firstExactInBuyMintsClaimsBeforeAnyETHExists() public {
        assertEq(address(manager).balance, 0);
        BalanceDelta delta = buy(-int256(0.1 ether), 500);
        assertEq(delta.amount0(), -int128(0.1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(address(manager).balance, 0.1 ether);
        assertEq(factory.hook().balanceOf(RECIPIENT), 0.005 ether);
        assertEq(manager.balanceOf(address(factory.hook()), 0), 0.005 ether);
        SwapTipHook launchHook = factory.hook();
        vm.prank(RECIPIENT);
        launchHook.claim();
        assertEq(RECIPIENT.balance, 0.005 ether);
        assertEq(manager.balanceOf(address(factory.hook()), 0), 0);
    }

    function test_firstExactOutBuyIntoETHEmptyPool() public {
        assertEq(address(manager).balance, 0);
        BalanceDelta delta = buy(int256(1_000_000 ether), 500);
        assertEq(delta.amount1(), int128(1_000_000 ether));
        assertLt(delta.amount0(), 0);
        assertGt(factory.hook().balanceOf(RECIPIENT), 0);
        assertEq(manager.balanceOf(address(factory.hook()), 0), factory.hook().balanceOf(RECIPIENT));
    }

    function test_firstBuyThenSellAndUnwindClaims() public {
        buy(-int256(1 ether), 1);
        BalanceDelta delta = router.swap(
            key,
            SwapParams(false, -int256(1_000_000 ether), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint16(500), RECIPIENT)
        );
        assertEq(delta.amount1(), -int128(1_000_000 ether));
        assertGt(delta.amount0(), 0);
        uint256 owed = factory.hook().balanceOf(RECIPIENT);
        assertEq(manager.balanceOf(address(factory.hook()), 0), owed);
        SwapTipHook launchHook = factory.hook();
        vm.prank(RECIPIENT);
        launchHook.claim();
        assertEq(RECIPIENT.balance, owed);
    }

    function testFuzz_firstBuy(uint96 rawSize, uint16 rawRate) public {
        uint256 size = bound(rawSize, 1, 1 ether);
        uint16 rate = uint16(bound(rawRate, 1, 500));
        BalanceDelta delta = buy(-int256(size), rate);
        assertEq(int256(delta.amount0()), -int256(size));
        assertEq(factory.hook().balanceOf(RECIPIENT), size * rate / 10000);
        assertEq(manager.balanceOf(address(factory.hook()), 0), size * rate / 10000);
    }

    function buy(int256 amount, uint16 bps) internal returns (BalanceDelta) {
        return router.swap{value: 2 ether}(
            key,
            SwapParams(true, amount, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(bps, RECIPIENT)
        );
    }

    receive() external payable {}
}
