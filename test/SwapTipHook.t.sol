// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SwapTipHook} from "../src/SwapTipHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Demonstrates that ERC-6909 claims can be gifted without consulting the hook.
contract ClaimDonor {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(address recipient) external payable {
        manager.unlock(abi.encode(recipient, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(Currency.wrap(address(0)));
        manager.settle{value: amount}();
        manager.mint(recipient, 0, amount);
        return "";
    }
}

contract ClaimReceiver {
    SwapTipHook public immutable hook;
    bool public reject;
    bool public reenter;
    bool public reentrySucceeded;
    uint256 public observedOwed;
    uint256 public observedClaims;

    constructor(SwapTipHook hook_) {
        hook = hook_;
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    function claim() external {
        hook.claim();
    }

    function claimInsideAnotherUnlock() external {
        hook.poolManager().unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(hook.poolManager()));
        hook.claim();
        return "";
    }

    receive() external payable {
        require(!reject, "reject ETH");
        observedOwed = hook.balanceOf(address(this));
        observedClaims = hook.poolManager().balanceOf(address(hook), 0);
        if (reenter) (reentrySucceeded,) = address(hook).call(abi.encodeCall(hook.claim, ()));
    }
}

contract SwapTipHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        deployCore();
        seedBalanced();
    }

    function test_permissionsExactlyCCAndConstructorValidation() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x00cc);
        assertEq(address(hook.poolManager()), address(manager));
        bytes memory code = abi.encodePacked(type(SwapTipHook).creationCode, abi.encode(manager));
        bytes32 salt = bytes32(uint256(123));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code)))))
        );
        assertFalse(HookFlags.matches(predicted, 0xcc));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapTipHook{salt: salt}(manager);
        vm.expectRevert(SwapTipHook.InvalidPoolManager.selector);
        new SwapTipHook(IPoolManager(address(0)));
    }

    function test_callbacksRejectNonManager() public {
        SwapParams memory params = paramsFor(0, 1 ether);
        vm.expectRevert(SwapTipHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SwapTipHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SwapTipHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(RECIPIENT, 1 ether));
        vm.prank(address(manager));
        vm.expectRevert(SwapTipHook.NoClaimInProgress.selector);
        hook.unlockCallback(abi.encode(RECIPIENT, 1 ether));
    }

    function test_allFourModesAtOneAndFiveHundredBps() public {
        for (uint8 mode; mode < 4; ++mode) {
            checkMode(mode, 1 ether, 1);
            checkMode(mode, 1 ether, 500);
        }
    }

    function testFuzz_exactSpecifiedAndFee(uint8 mode, uint96 size, uint16 rate) public {
        checkMode(mode % 4, bound(size, 1, 100 ether), uint16(bound(rate, 1, 500)));
    }

    function checkMode(uint8 mode, uint256 amount, uint16 bps) internal {
        uint256 snap = vm.snapshotState();
        uint256 beforeOwed = hook.balanceOf(RECIPIENT);
        bool ethSpecified = mode == 0 || mode == 3;
        uint256 fee = amount * bps / 10000;
        // Execute the mathematically equivalent raw pool swap from the same pre-swap state.
        uint256 rawAmount = ethSpecified ? (mode == 0 ? amount - fee : amount + fee) : amount;
        BalanceDelta raw = swap(mode, rawAmount, "");
        if (!ethSpecified) fee = abs128(raw.amount0()) * bps / 10000;
        vm.revertToState(snap);
        uint256[2] memory balancesBefore = [address(this).balance, token.balanceOf(address(this))];
        vm.recordLogs();
        BalanceDelta actual = swap(mode, amount, abi.encode(bps, RECIPIENT));
        assertEq(int256(actual.amount0()), int256(raw.amount0()) - int256(fee), "ETH debit/credit");
        assertEq(int256(actual.amount1()), int256(raw.amount1()), "token leg unchanged");
        assertEq(
            ethSpecified ? int256(actual.amount0()) : int256(actual.amount1()),
            paramsFor(mode, amount).amountSpecified
        );
        assertEq(int256(address(this).balance) - int256(balancesBefore[0]), int256(actual.amount0()));
        assertEq(int256(token.balanceOf(address(this))) - int256(balancesBefore[1]), int256(actual.amount1()));
        assertEq(hook.balanceOf(RECIPIENT), beforeOwed + fee);
        assertEq(hook.totalTipped(key.toId()), beforeOwed + fee);
        assertEq(hook.tippedBy(tx.origin), beforeOwed + fee);
        assertEq(hook.receivedBy(RECIPIENT), beforeOwed + fee);
        assertClaims(beforeOwed + fee);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            ++count;
            assertEq(logs[i].topics[0], keccak256("Tipped(bytes32,address,address,uint16,uint256)"));
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(tx.origin))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(RECIPIENT))));
            assertEq(logs[i].data, abi.encode(bps, fee));
        }
        assertEq(count, fee == 0 ? 0 : 1);
    }

    function test_dustAllModes() public {
        for (uint8 mode; mode < 4; ++mode) {
            checkMode(mode, 1, 1);
            checkMode(mode, 1, 500);
        }
        assertClaims(0);
    }

    function assertNoTip(bytes memory data) internal {
        for (uint8 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            BalanceDelta baseline = swap(mode, 1 ether, "");
            vm.revertToState(snap);
            vm.recordLogs();
            BalanceDelta actual = swap(mode, 1 ether, data);
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(baseline));
            assertClaims(0);
            assertEq(hook.totalTipped(key.toId()), 0);
            assertEq(hook.tippedBy(tx.origin), 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(logs[j].emitter != address(hook));
            }
        }
    }

    function test_invalidTipsChargeNothing() public {
        assertNoTip(abi.encode(uint16(0), RECIPIENT));
        assertNoTip(abi.encode(uint16(500), address(0)));
        assertNoTip(abi.encode(uint16(500), address(hook)));
        assertNoTip(abi.encode(uint16(500), address(manager)));
        assertNoTip(abi.encode(uint256(500), uint256(1) << 160));
        assertNoTip(abi.encode(uint256(500), type(uint256).max));
        assertNoTip("");
        assertNoTip(hex"ffff");
        assertNoTip(abi.encode(uint256(500)));
        assertNoTip(abi.encode(uint256(500), RECIPIENT, uint256(1)));
    }

    function testFuzz_badLengthsCannotDecodeRevert(bytes memory data) public {
        vm.assume(data.length != 64);
        swap(0, 1 ether, data);
        assertClaims(0);
        assertEq(hook.balanceOf(RECIPIENT), 0);
    }

    function testFuzz_dirtyRecipientWordIgnored(uint256 raw) public {
        uint256 dirty = raw | (uint256(1) << 160);
        swap(1, 1 ether, abi.encode(uint256(500), dirty));
        assertClaims(0);
    }

    function wrapped(bytes4 callback, bytes4 errorSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(errorSelector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_501AndOversizedRateRevertWithoutTruncation() public {
        uint256[4] memory rates = [uint256(501), uint256(65536), uint256(65537), type(uint256).max];
        for (uint256 j; j < rates.length; ++j) {
            for (uint8 mode; mode < 4; ++mode) {
                vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SwapTipHook.TipTooHigh.selector));
                swap(mode, 1 ether, abi.encode(rates[j], RECIPIENT));
            }
        }
        assertClaims(0);
    }

    function test_excessiveRateTakesPrecedenceOverBadRecipient() public {
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, SwapTipHook.TipTooHigh.selector));
        swap(0, 1 ether, abi.encode(uint256(501), type(uint256).max));
    }

    function test_partialFillAllModesWithAndWithoutTipRollsBack() public {
        for (uint8 mode; mode < 4; ++mode) {
            for (uint16 bps; bps <= 500; bps += 500) {
                SwapParams memory params = paramsFor(mode, 100 ether);
                params.sqrtPriceLimitX96 = mode < 2 ? Q96 - 1 : Q96 + 1;
                vm.expectRevert(wrapped(IHooks.afterSwap.selector, SwapTipHook.PartialFill.selector));
                router.swap{value: 300 ether}(
                    key, params, PoolSwapTest.TestSettings(false, false), abi.encode(bps, RECIPIENT)
                );
                assertClaims(0);
                assertEq(hook.balanceOf(RECIPIENT), 0);
                (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                assertEq(price, Q96);
            }
        }
    }

    function test_claimPaysOnceAndKeepsLifetimeViews() public {
        swap(0, 1 ether, abi.encode(uint16(500), RECIPIENT));
        uint256 amount = hook.balanceOf(RECIPIENT);
        uint256 beforeBalance = RECIPIENT.balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapTipHook.Claimed(RECIPIENT, amount);
        vm.prank(RECIPIENT);
        hook.claim();
        assertEq(RECIPIENT.balance, beforeBalance + amount);
        assertEq(hook.balanceOf(RECIPIENT), 0);
        assertEq(hook.receivedBy(RECIPIENT), amount);
        assertEq(hook.totalTipped(key.toId()), amount);
        assertClaims(0);
        vm.prank(RECIPIENT);
        vm.expectRevert(SwapTipHook.NothingToClaim.selector);
        hook.claim();
    }

    function test_reentrantClaimObservesZeroDebtAndCannotDoublePay() public {
        ClaimReceiver recipient = new ClaimReceiver(hook);
        recipient.configure(false, true);
        swap(0, 1 ether, abi.encode(uint16(500), address(recipient)));
        recipient.claim();
        assertEq(address(recipient).balance, 0.05 ether);
        assertFalse(recipient.reentrySucceeded());
        assertEq(recipient.observedOwed(), 0);
        assertEq(recipient.observedClaims(), 0);
        assertClaims(0);
    }

    function test_rejectedPayoutRollsBackAndCanRetry() public {
        ClaimReceiver recipient = new ClaimReceiver(hook);
        recipient.configure(true, false);
        swap(0, 1 ether, abi.encode(uint16(500), address(recipient)));
        vm.expectRevert();
        recipient.claim();
        assertEq(hook.balanceOf(address(recipient)), 0.05 ether);
        assertClaims(0.05 ether);
        recipient.configure(false, false);
        recipient.claim();
        assertEq(address(recipient).balance, 0.05 ether);
        assertClaims(0);
    }

    function test_onlyRecipientCanClaimNoRouterCredit() public {
        swap(0, 1 ether, abi.encode(uint16(500), RECIPIENT));
        assertEq(hook.balanceOf(address(router)), 0);
        vm.expectRevert(SwapTipHook.NothingToClaim.selector);
        hook.claim();
        assertClaims(0.05 ether);
    }

    function test_claimInsideExistingUnlockRevertsAndPreservesDebt() public {
        ClaimReceiver recipient = new ClaimReceiver(hook);
        swap(0, 1 ether, abi.encode(uint16(500), address(recipient)));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        recipient.claimInsideAnotherUnlock();
        assertEq(hook.balanceOf(address(recipient)), 0.05 ether);
        assertClaims(0.05 ether);
        recipient.claim();
        assertClaims(0);
    }

    function test_failedSwapSettlementRollsBackTip() public {
        token.approve(address(router), 0);
        vm.expectRevert();
        swap(3, 1 ether, abi.encode(uint16(500), RECIPIENT));
        assertClaims(0);
        assertEq(hook.balanceOf(RECIPIENT), 0);
        assertEq(hook.totalTipped(key.toId()), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, Q96);
    }

    function test_unsolicitedClaimsCreateSurplusWithoutNewDebt() public {
        swap(0, 1 ether, abi.encode(uint16(500), RECIPIENT));
        ClaimDonor donor = new ClaimDonor(manager);
        donor.donate{value: 1}(address(hook));
        assertEq(hook.balanceOf(RECIPIENT), 0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.05 ether + 1);
        vm.prank(RECIPIENT);
        hook.claim();
        assertEq(hook.balanceOf(RECIPIENT), 0);
        assertEq(manager.balanceOf(address(hook), 0), 1);
    }

    function test_nonNativePoolIgnoresEvenOversizedRate() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 10_000_000 ether);
        address a = address(token) < address(other) ? address(token) : address(other);
        address b = address(token) < address(other) ? address(other) : address(token);
        PoolKey memory nonNative =
            PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        manager.initialize(nonNative, Q96);
        other.approve(address(liquidityRouter), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            nonNative, ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), ""
        );
        for (uint8 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            BalanceDelta baseline =
                router.swap(nonNative, paramsFor(mode, 1 ether), PoolSwapTest.TestSettings(false, false), "");
            vm.revertToState(snap);
            BalanceDelta actual = router.swap(
                nonNative,
                paramsFor(mode, 1 ether),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(type(uint256).max, RECIPIENT)
            );
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(baseline));
        }
        assertEq(hook.totalTipped(nonNative.toId()), 0);
        assertClaims(0);
    }

    function test_poolTotalsAreSeparateRecipientClaimsAggregate() public {
        swap(0, 1 ether, abi.encode(uint16(500), RECIPIENT));
        PoolId firstId = key.toId();
        key.fee = 500;
        seedBalanced();
        swap(0, 2 ether, abi.encode(uint16(100), RECIPIENT));
        assertEq(hook.totalTipped(firstId), 0.05 ether);
        assertEq(hook.totalTipped(key.toId()), 0.02 ether);
        assertEq(hook.balanceOf(RECIPIENT), 0.07 ether);
        assertClaims(0.07 ether);
    }
}
