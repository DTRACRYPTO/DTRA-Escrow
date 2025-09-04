// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/DTRAOracle.sol";
import "../contracts/DTRAICO.sol";
import "../contracts/DTRAStaking.sol";
import "../contracts/DTRASwap.sol";

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy Oracle
        DTRAOracle oracle = new DTRAOracle();

        // 2. Deploy DTRA token
        address dtra = deployToken();

        // 3. Deploy ICO
        DTRAICO ico = new DTRAICO(dtra, address(oracle));

        // 4. Deploy Staking
        DTRAStaking staking = new DTRAStaking(dtra);

        // 5. Deploy Swap
        address teamWallet = msg.sender; // Can be multisig later
        DTRASwap swap = new DTRASwap(dtra, address(oracle), teamWallet);

        vm.stopBroadcast();
    }

    function deployToken() internal returns (address) {
        // Replace with actual DTRA token contract deployment
        // For demo: use standard ERC20 or OpenZeppelin
        revert("Implement your token deployment here");
    }
}
