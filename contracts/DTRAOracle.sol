// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract DTRAOracle {
    address public owner;
    mapping(string => uint256) public prices; // asset => price in USD (8 decimals)

    event PriceUpdated(string asset, uint256 price);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function updatePrice(string calldata asset, uint256 price) external onlyOwner {
        prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    function getPrice(string calldata asset) external view returns (uint256) {
        return prices[asset];
    }
}
