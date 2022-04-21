require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-waffle");
require("hardhat-deploy");
require("hardhat-deploy-ethers");
require("solidity-coverage");
require('dotenv').config();
require("@nomiclabs/hardhat-etherscan");


 module.exports = {
  networks: {
    hardhat: {
      // comment out for local testing
      // uncomment for fork script
      // forking: {
      //   url: "",
      //   enabled: false,
      // },
    },
    rinkeby: {
      url: process.env.ALCHEMY_RINKEBY_URL,
      accounts: [process.env.DEV_PRIVATE_KEY],
    },
    tevmos: {
      url: "https://eth.bd.evmos.dev:8545",
      accounts: [process.env.DEV_PRIVATE_KEY]
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.8.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.6.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  etherscan: {
    mainnet: process.env.ETHERSCAN_KEY,
    evmosTestnet: process.env.ETHERSCAN_KEY
  }
};
