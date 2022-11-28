//SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initial_supply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initial_supply);
    }
}