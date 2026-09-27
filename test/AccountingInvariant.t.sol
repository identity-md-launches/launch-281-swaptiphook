// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {STIP} from "../src/STIP.sol";
import {SwapTipHook} from "../src/SwapTipHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AccountingHandler is Test {
    SwapTipHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolKey[2] internal keys;
    address[4] public recipients = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public ghostPaid;
    uint256 public swaps;
    uint256 public claims;

    constructor(
        SwapTipHook hook_,
        STIP token,
        PoolSwapTest router_,
        PoolKey memory first,
        PoolKey memory second
    ) {
        hook = hook_;
        router = router_;
        keys[0] = first;
        keys[1] = second;
        token.approve(address(router), type(uint256).max);
    }

    function tip(uint8 modeRaw, uint96 rawSize, uint16 rateRaw, uint8 recipientRaw, bool second) external {
        uint8 mode = modeRaw % 4;
        uint256 amount = bound(rawSize, 1, 2 ether);
        uint16 rate = uint16(bound(rateRaw, 0, 500));
        address recipient = recipients[recipientRaw % 4];
        SwapParams memory params = SwapParams(
            mode < 2,
            mode % 2 == 0 ? -int256(amount) : int256(amount),
            mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        router.swap{value: mode < 2 ? 10 ether : 0}(
            keys[second ? 1 : 0], params, PoolSwapTest.TestSettings(false, false), abi.encode(rate, recipient)
        );
        ++swaps;
    }

    function claim(uint8 rawRecipient) external {
        address recipient = recipients[rawRecipient % 4];
        uint256 amount = hook.balanceOf(recipient);
        if (amount == 0) return;
        uint256 ethBefore = recipient.balance;
        vm.prank(recipient);
        hook.claim();
        assertEq(recipient.balance - ethBefore, amount);
        ghostPaid += amount;
        ++claims;
    }

    function sumOwed() external view returns (uint256 owed) {
        for (uint256 i; i < 4; ++i) {
            owed += hook.balanceOf(recipients[i]);
        }
    }

    function sumReceived() external view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += hook.receivedBy(recipients[i]);
        }
    }

    function poolTotals() external view returns (uint256) {
        return hook.totalTipped(keys[0].toId()) + hook.totalTipped(keys[1].toId());
    }

    receive() external payable {}
}

contract AccountingInvariantTest is HookFixture {
    AccountingHandler internal handler;

    function setUp() public {
        deployCore();
        seedBalanced();
        PoolKey memory first = key;
        key.fee = 500;
        seedBalanced();
        handler = new AccountingHandler(hook, token, router, first, key);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AccountingHandler.tip.selector;
        selectors[1] = AccountingHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_recipientSumEqualsETHClaims() public view {
        assertEq(handler.sumOwed(), manager.balanceOf(address(hook), 0));
        assertEq(handler.sumReceived(), handler.sumOwed() + handler.ghostPaid());
        assertEq(handler.poolTotals(), handler.sumReceived());
        assertEq(address(hook).balance, 0);
    }

    function testFuzz_interleavedAccounting(uint256 seed) public {
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            handler.tip(
                uint8(seed), uint96(seed >> 8), uint16(seed >> 104), uint8(seed >> 120), (seed & 256) != 0
            );
            if ((seed & 16) != 0) handler.claim(uint8(seed >> 128));
            invariant_recipientSumEqualsETHClaims();
        }
        for (uint8 i; i < 4; ++i) {
            handler.claim(i);
        }
        assertClaims(0);
        invariant_recipientSumEqualsETHClaims();
    }
}
