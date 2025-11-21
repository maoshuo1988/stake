module.exports = async ({ getNamedAccounts, deployments, network, ethers }) => {
  const fs = require('fs');
  const path = require('path');

  let cachePath = path.join(__dirname, '..', 'cache', 'store', `${network.name}.json`);
  if (!fs.existsSync(cachePath)) {
    // fallback to sepolia.json if available (useful when running coverage/local tests)
    const fallback = path.join(__dirname, '..', 'cache', 'store', `sepolia.json`);
    if (fs.existsSync(fallback)) {
      console.log(`[deploy] cache for ${network.name} not found, falling back to sepolia.json`);
      cachePath = fallback;
    } else {
      console.log(`[deploy] cache not found at ${cachePath}, skipping add-pools-from-cache`);
      return;
    }
  }

  const data = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  const metaNodeStakeAddr = data.MetaNodeStake;
  const stakeTokenAddr = data.StakeToken;
  const adminAddr = data.deployer;

  if (!metaNodeStakeAddr) {
    console.log('[deploy] MetaNodeStake address not found in cache, skipping');
    return;
  }

  console.log(`[deploy] found MetaNodeStake=${metaNodeStakeAddr}, stakeToken=${stakeTokenAddr}, admin=${adminAddr}`);

  // try to get signer for admin. If not available (e.g. running on local), impersonate when possible
  let signer;
  try {
    signer = await ethers.getSigner(adminAddr);
  } catch (e) {
    // If network supports impersonation (hardhat, localhost), try
    if (network.name === 'hardhat' || network.name === 'localhost' || network.name === 'coverage') {
      console.log('[deploy] impersonating admin for local network');
      await ethers.provider.send('hardhat_impersonateAccount', [adminAddr]);
      signer = await ethers.getSigner(adminAddr);

      // fund impersonated account so it can pay gas
      const [funder] = await ethers.getSigners();
      await funder.sendTransaction({ to: adminAddr, value: ethers.parseEther('1') }).catch(() => {});
    } else {
      console.log('[deploy] cannot obtain signer for admin and network does not support impersonation');
      return;
    }
  }

  // attach to existing contract
  const metaNodeStake = await ethers.getContractAt('MetaNodeStake', metaNodeStakeAddr, signer);

  // Add default pools: ETH pool (pid=0) and stake token pool (if stake token available)
  try {
    // add ETH pool: stTokenAddress = zero address, weight=10, minDeposit=0, unstakeLockedBlocks=2, withUpdate=false
    const tx1 = await metaNodeStake.addPool(ethers.ZeroAddress, 10, 0, 2, false);
    await tx1.wait();
    console.log('[deploy] added ETH pool');
  } catch (e) {
    console.log('[deploy] addPool ETH failed or already added:', e && e.message ? e.message : e);
  }

  if (stakeTokenAddr) {
    try {
      const tx2 = await metaNodeStake.addPool(stakeTokenAddr, 20, 0, 2, false);
      await tx2.wait();
      console.log('[deploy] added stake token pool');
    } catch (e) {
      console.log('[deploy] addPool stake token failed or already added:', e && e.message ? e.message : e);
    }
  }

  // stop impersonation if we started it
  try {
    if (network.name === 'hardhat' || network.name === 'localhost' || network.name === 'coverage') {
      await ethers.provider.send('hardhat_stopImpersonatingAccount', [adminAddr]);
    }
  } catch (e) {}
};

module.exports.tags = ['MetaNodeStake', 'addPoolsFromCache'];
