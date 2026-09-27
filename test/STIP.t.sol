// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {STIP} from "../src/STIP.sol";

contract STIPTest is Test {
    STIP internal token;
    address internal constant USER = address(0xbeef);

    function setUp() public {
        token = new STIP();
    }

    function test_supplyAndMetadata() public view {
        assertEq(token.name(), "Swap Tip");
        assertEq(token.symbol(), "STIP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferConservesSupply(uint256 raw) public {
        uint256 amount = bound(raw, 0, token.totalSupply());
        assertTrue(token.transfer(USER, amount));
        assertEq(token.balanceOf(USER), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        vm.prank(USER);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_allowanceAndFailures() public {
        token.approve(USER, 10 ether);
        vm.prank(USER);
        token.transferFrom(address(this), USER, 4 ether);
        assertEq(token.allowance(address(this), USER), 6 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, USER, 6 ether, 7 ether)
        );
        vm.prank(USER);
        token.transferFrom(address(this), USER, 7 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, USER, 4 ether, 5 ether)
        );
        vm.prank(USER);
        token.transfer(address(this), 5 ether);
    }

    function test_infiniteAllowance() public {
        token.approve(USER, type(uint256).max);
        vm.prank(USER);
        token.transferFrom(address(this), USER, 1 ether);
        assertEq(token.allowance(address(this), USER), type(uint256).max);
    }

    function test_adminSelectorsAbsentForEveryone() public {
        string[10] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.prank(j == 0 ? USER : address(this));
                (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], USER, 1 ether));
                assertFalse(ok);
            }
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(USER), 0);
    }
}
