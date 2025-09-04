// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BTCReceiver {
    address public validator;
    mapping(bytes32 => bool) public processedTxs;

    event BTCReceived(address user, uint256 btcAmount, uint256 hbarEquivalent);

    constructor(address _validator) {
        validator = _validator;
    }

    modifier onlyValidator() {
        require(msg.sender == validator, "Not validator");
        _;
    }

    function confirmBTCDeposit(address user, uint256 btcAmount, uint256 hbarEquivalent, bytes32 txHash) external onlyValidator {
        require(!processedTxs[txHash], "Already processed");
        processedTxs[txHash] = true;

        // You can call ICO or Swap contract from here to credit user in HBAR/DTRA
        emit BTCReceived(user, btcAmount, hbarEquivalent);
    }
}
