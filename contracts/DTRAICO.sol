// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IOracle {
    function getPrice(string calldata asset) external view returns (uint256);
}

contract DTRAICO {
    address public owner;
    IERC20 public dtraToken;
    IOracle public oracle;

    uint256 public constant DTRA_PRICE_USD = 100 * 1e8; // 8 decimals

    uint256 public startTime;
    uint256 public currentTier = 0;

    struct Tier {
        uint256 endTime;
        uint256 maxTokens;
        uint256 soldTokens;
        uint256 discountPercent; // 100 = base price, 110 = 10% premium
    }

    Tier[4] public tiers;

    event Purchased(address indexed buyer, uint256 hbarAmount, uint256 dtraAmount, uint256 tier);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _token, address _oracle) {
        owner = msg.sender;
        dtraToken = IERC20(_token);
        oracle = IOracle(_oracle);
        startTime = block.timestamp;

        tiers[0] = Tier(startTime + 7 days, 1_000e18, 0, 90);
        tiers[1] = Tier(startTime + 14 days, 2_000e18, 0, 100);
        tiers[2] = Tier(startTime + 21 days, 3_000e18, 0, 110);
        tiers[3] = Tier(startTime + 28 days, 4_000e18, 0, 120);
    }

    function buyWithHbar() external payable {
        require(msg.value > 0, "No HBAR");

        _checkTier();
        Tier storage tier = tiers[currentTier];

        uint256 hbarPrice = oracle.getPrice("HBAR"); // 8 decimals

        uint256 usdValue = (msg.value * hbarPrice) / 1e8;
        uint256 adjustedUSD = (usdValue * 100) / tier.discountPercent;
        uint256 dtraAmount = (adjustedUSD * 1e18) / DTRA_PRICE_USD;

        require(tier.soldTokens + dtraAmount <= tier.maxTokens, "Tier full");

        tier.soldTokens += dtraAmount;
        require(dtraToken.transfer(msg.sender, dtraAmount), "Token transfer failed");

        emit Purchased(msg.sender, msg.value, dtraAmount, currentTier);
    }

    function _checkTier() internal {
        while (currentTier < 3 &&
            (block.timestamp > tiers[currentTier].endTime ||
             tiers[currentTier].soldTokens >= tiers[currentTier].maxTokens)) {
            currentTier++;
        }
    }

    function withdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = IOracle(_oracle);
    }
}
