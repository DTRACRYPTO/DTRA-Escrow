// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract DTRAStaking {
    IERC20 public dtraToken;
    address public owner;

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 rewardDebt;
    }

    mapping(address => StakeInfo) public stakes;

    uint256 public constant MIN_STAKE_TIME = 2 days;
    uint256 public constant BOOST_TIME = 90 days;

    event Staked(address user, uint256 amount);
    event Withdrawn(address user, uint256 amount, uint256 reward);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _token) {
        owner = msg.sender;
        dtraToken = IERC20(_token);
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Zero stake");

        StakeInfo storage s = stakes[msg.sender];
        require(s.amount == 0, "Already staking");

        dtraToken.transferFrom(msg.sender, address(this), amount);

        s.amount = amount;
        s.startTime = block.timestamp;
        s.rewardDebt = 0;

        emit Staked(msg.sender, amount);
    }

    function withdraw() external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount > 0, "No stake");

        uint256 timeElapsed = block.timestamp - s.startTime;
        require(timeElapsed >= MIN_STAKE_TIME, "Too early");

        uint256 apy = 550; // 5.5% in basis points
        if (timeElapsed >= BOOST_TIME) apy = 666;

        // Extra APY per 50 DTRA
        uint256 bonus = (s.amount / 50e18) * 25; // 0.25% = 25 bps
        apy += bonus;

        // Cap APY if needed
        if (apy > 1000) apy = 1000;

        uint256 reward = (s.amount * apy * timeElapsed) / (365 days * 10000);

        uint256 total = s.amount + reward;

        delete stakes[msg.sender];

        dtraToken.transfer(msg.sender, total);

        emit Withdrawn(msg.sender, s.amount, reward);
    }
}
