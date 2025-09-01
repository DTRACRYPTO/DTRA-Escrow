require("dotenv").config();
const { ethers } = require("hardhat");

async function main() {
  const { DTRA_TOKEN, TREASURY } = process.env;
  if (!DTRA_TOKEN || !TREASURY) throw new Error("Set DTRA_TOKEN & TREASURY in .env");

  const Vault = await ethers.getContractFactory("DTRAVestingVault");
  const vault = await Vault.deploy(DTRA_TOKEN);
  await vault.deployed();
  console.log("VestingVault:", vault.address);

  const cap = ethers.utils.parseUnits("10000000", 8); // 10M DTRA
  const Sale = await ethers.getContractFactory("DTRACrowdsale");
  const sale = await Sale.deploy(DTRA_TOKEN, TREASURY, cap);
  await sale.deployed();
  console.log("Crowdsale:", sale.address);

  await (await sale.setVesting(vault.address)).wait();
  const num = ethers.utils.parseUnits("5", 8); // 1 HBAR -> 5 DTRA (example)
  const den = ethers.utils.parseUnits("1", 8);
  await (await sale.setPrice(ethers.constants.AddressZero, num, den, true)).wait();
  console.log("HBAR price set");
}

main().catch((e) => { console.error(e); process.exit(1); });
