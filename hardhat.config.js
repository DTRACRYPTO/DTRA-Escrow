require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.20",
  networks: {
    hederaTestnet: {
      url: process.env.HEDERA_RPC_URL || "https://testnet.hashio.io/api",
      accounts: [process.env.PRIVATE_KEY].filter(Boolean),
    },
  },
};
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.20",
  networks: {
    hederaTestnet: {
      url: process.env.HEDERA_RPC_URL,
      accounts: [process.env.HEDERA_OPERATOR_KEY],
    },
  },
};

require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.20",
  networks: {
    hederaTestnet: {
      url: process.env.HEDERA_RPC_URL || "https://testnet.hashio.io/api",
      accounts: [process.env.HEDERA_OPERATOR_KEY],
    },
  },
};

// hardhat.config.js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const accounts =
  process.env.HEDERA_OPERATOR_KEY && process.env.HEDERA_OPERATOR_KEY.startsWith("0x")
    ? [process.env.HEDERA_OPERATOR_KEY]
    : undefined;

module.exports = {
  solidity: "0.8.20",
  networks: {
    hederaTestnet: {
      url: process.env.HEDERA_RPC_URL || "https://testnet.hashio.io/api",
      accounts, // undefined if not set -> avoids the "expected string, received undefined" error
    },
  },
};

