const { expect } = require('chai');
const hre = require('hardhat');
const { ethers, deployments } = hre;

describe('TestToken basic tests', function () {
  it('owner can mint and faucet; non-owner cannot', async function () {
    await deployments.fixture(['MetaNodeStake']);
    const depMeta = await deployments.get('MetaNode').catch(() => null);
    const depStake = await deployments.get('StakeToken').catch(() => null);
    const signers = await ethers.getSigners();
    const owner = signers[0];
    const nonOwner = signers[1] || signers[0];

    // pick StakeToken for testing
    const tokenAddr = depStake ? depStake.address : (depMeta ? depMeta.address : null);
    expect(tokenAddr, 'no TestToken deployed by fixture').to.be.ok;

    const tokenAsOwner = await ethers.getContractAt('TestToken', tokenAddr, owner);
    const tokenAsNon = await ethers.getContractAt('TestToken', tokenAddr, nonOwner);

    // balances
    const to = await signers[2] ? signers[2].address : nonOwner.address;

    // owner mint
    await expect(tokenAsOwner.mint(to, ethers.parseUnits('10', 18))).to.not.be.reverted;
    const bal = await tokenAsOwner.balanceOf(to);
    expect(bal > 0n).to.be.true;

    // faucet: owner can mint to multiple
    const tos = [to, owner.address];
    const ams = [ethers.parseUnits('1', 18), ethers.parseUnits('2', 18)];
    await expect(tokenAsOwner.faucet(tos, ams)).to.not.be.reverted;

    // non-owner mint/faucet should revert (onlyOwner)
    await expect(tokenAsNon.mint(to, ethers.parseUnits('1', 18))).to.be.reverted;
    await expect(tokenAsNon.faucet(tos, ams)).to.be.reverted;
  });
});
