const { deployments, ethers } = require('hardhat');
const { expect } = require('chai');
const fs = require('fs');
const path = require('path');

describe('deploy script', function () {
  it('runs deployments and writes cache/store/<network>.json with abi and addresses', async function () {
    // run all deployments
    await deployments.fixture();

    const networkName = network.name;
    const outPath = path.join(__dirname, '..', 'cache', 'store', `${networkName}.json`);

    // file should exist
    expect(fs.existsSync(outPath)).to.equal(true);

    const content = JSON.parse(fs.readFileSync(outPath, 'utf8'));

    expect(content).to.have.property('MetaNode');
    expect(content).to.have.property('StakeToken');
    expect(content).to.have.property('MetaNodeStake');
    expect(content).to.have.property('abi');
    expect(Array.isArray(content.abi)).to.equal(true);
  });
});
