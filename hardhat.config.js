require("@nomicfoundation/hardhat-toolbox");
require("solidity-coverage");
require("hardhat-deploy");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  plugins: ["solidity-coverage"],
  networks: {
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PK]
    }
  },
  namedAccounts: {
    deployer: 0,
    seller: 0,
    buyer: 0
  }
};
