// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestToken is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {
        // constructor keeps deployer as owner (Ownable)
    }

    /**
     * @notice mint tokens to an address. Restricted to owner to avoid open mint in non-test env.
     * In local tests we deployer == owner, so tests can mint freely.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice convenience faucet to mint for multiple addresses in a single tx (reduces test overhead)
     */
    function faucet(address[] calldata tos, uint256[] calldata amounts) external onlyOwner {
        require(tos.length == amounts.length, "TestToken: length mismatch");
        for (uint256 i = 0; i < tos.length; i++) {
            _mint(tos[i], amounts[i]);
        }
    }
}
