// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IOracle {
    function getPrice(string calldata asset) external view returns (uint256);
}

contract DTRASwap {
    IERC20 public dtra;
    address public owner;
    address public teamWallet;
    IOracle public oracle;

    uint256 public constant FEE = 0.0001 ether; // 0.0001 DTRA

    event Swapped(address indexed user, string fromAsset, string toAsset, uint256 amount, uint256 result);

    constructor(address _dtra, address _oracle, address _teamWallet) {
        owner = msg.sender;
        dtra = IERC20(_dtra);
        oracle = IOracle(_oracle);
        teamWallet = _teamWallet;
    }

    function dtraToHbar(uint256 dtraAmount) external {
        require(dtraAmount > FEE, "Too small");

        uint256 amountAfterFee = dtraAmount - FEE;

        dtra.transferFrom(msg.sender, address(this), dtraAmount);
        dtra.transfer(teamWallet, FEE);

        uint256 hbarPrice = oracle.getPrice("HBAR");
        uint256 usdValue = (amountAfterFee * 100 * 1e8) / 1e18; // DTRA = $100
        uint256 hbarAmount = (usdValue * 1e8) / hbarPrice;

        payable(msg.sender).transfer(hbarAmount);

        emit Swapped(msg.sender, "DTRA", "HBAR", dtraAmount, hbarAmount);
    }

    function hbarToDtra() external payable {
        require(msg.value > 0, "No HBAR");

        uint256 hbarPrice = oracle.getPrice("HBAR");
        uint256 usdValue = (msg.value * hbarPrice) / 1e8;
        uint256 dtraAmount = (usdValue * 1e18) / (100 * 1e8);

        require(dtraAmount > FEE, "Too small");
        uint256 amountAfterFee = dtraAmount - FEE;

        dtra.transfer(msg.sender, amountAfterFee);
        dtra.transfer(teamWallet, FEE);

        emit Swapped(msg.sender, "HBAR", "DTRA", msg.value, amountAfterFee);
    }
}
