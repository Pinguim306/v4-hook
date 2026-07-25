// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

/// @notice Minimal WETH9-style wrapper for a chain's native currency, for chains that ship
///   without a canonical wrapped-native (e.g. Circle's Arc, whose native gas is USDC). Wraps
///   1:1 against `msg.value`; `decimals` mirrors the chain's native scaling and is fixed at
///   deploy (Arc: 6). Uniswap v4's PositionManager requires a wrapped-native address, which is
///   the only reason Coil needs this — pools themselves use the raw native currency.
contract WrappedNative is ERC20 {
    error NativeSendFailed();

    event Deposit(address indexed to, uint256 amount);
    event Withdrawal(address indexed from, uint256 amount);

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
        emit Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        deposit();
    }
}
