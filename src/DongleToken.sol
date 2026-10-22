// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Dongle (DONGLE)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no mint, no burn, no pause, no blacklist, no fee
/// and no upgrade path: after deployment the contract has no privileged functions at all.
/// @dev The deployer is the launch factory. It receives the full 1,000,000,000 DONGLE and pays
/// every allocation out of that balance; nothing here reserves or redirects any of it.
contract DongleToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Dongle";

    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "DONGLE";

    /// @notice Number of decimals; the standard 18.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in whole tokens, minted exactly once.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The whole supply in minor units (wei of DONGLE): 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. Takes no arguments and calls no other contract.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
