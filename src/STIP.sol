// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply token. Its deployer (the launch factory) receives the entire supply.
contract STIP is ERC20 {
    constructor() ERC20("Swap Tip", "STIP") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
