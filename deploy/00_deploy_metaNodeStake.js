module.exports = async ({ getNamedAccounts, deployments, network, ethers }) => {
  const { deployer } = await getNamedAccounts();
  const { deploy, save, log } = deployments;
  const fs = require("fs");
  const path = require("path");

  // 获取 signer（回退到第一个本地 signer）
  let signer;
  try {
    signer = await ethers.getSigner(deployer);
  } catch {
    signer = (await ethers.getSigners())[0];
  }

  log(`部署者: ${deployer} (${signer.address})`);

  // 使用 hardhat-deploy 部署/注册示例 ERC20 作为 MetaNode 与 StakeToken（TestToken 仅为示例）
  const metaNodeDeployment = await deploy("MetaNode", {
    from: deployer,
    contract: "TestToken",
    args: ["MetaNode", "MN"],
    log: true,
  });

  const stakeTokenDeployment = await deploy("StakeToken", {
    from: deployer,
    contract: "TestToken",
    args: ["StakeToken", "ST"],
    log: true,
  });

  log(
    `已部署/注册 MetaNode=${metaNodeDeployment.address}, StakeToken=${stakeTokenDeployment.address}`
  );

  const MetaNodeStakeFactory = await ethers.getContractFactory(
    "MetaNodeStake",
    signer
  );
  const { upgrades } = require("hardhat");

  // 计算初始化参数：initialize(IERC20 _MetaNode, uint256 _startBlock, uint256 _endBlock, uint256 _MetaNodePerBlock)
  const currentBlock = await ethers.provider.getBlockNumber();
  const startBlock = currentBlock + 1;
  const endBlock = startBlock + 100000; // 可根据需要调整
  const metaNodePerBlock = 1; // 如需 token 精度请使用 ethers.parseUnits("1", decimals)

  // deploy proxy 并等待
  const proxy = await upgrades.deployProxy(
    MetaNodeStakeFactory,
    [metaNodeDeployment.address, startBlock, endBlock, metaNodePerBlock],
    { initializer: "initialize", kind: "uups" }
  );
  await proxy.waitForDeployment();
  let proxyAddress = await proxy.getAddress();

  log(`已通过 proxy 部署 MetaNodeStake（可升级）=${proxyAddress}`);
  // 注册到 hardhat-deploy，便于 tests 使用 hre.deployments.get / fixture
  await save("MetaNodeStake", {
    abi: MetaNodeStakeFactory.interface.format("json"),
    address: proxyAddress,
  });

  // 保存实现合约地址（可选）
  const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  await save("MetaNodeStake_Implementation", {
    abi: MetaNodeStakeFactory.interface.format("json"),
    address: implAddress,
  });
  log(`已注册 MetaNodeStake：proxy=${proxyAddress}, impl=${implAddress}`);
  // ----------------- 将部署信息写入 cache/store/<network>.json（与 sepolia.json 格式一致） -----------------
  try {
    const netName = network.name || "hardhat";
    const networkInfo = await ethers.provider.getNetwork();
    const chainId = networkInfo.chainId ? String(networkInfo.chainId) : "";
    const blockNumber = await ethers.provider.getBlockNumber();
    const block = await ethers.provider.getBlock(blockNumber);
    const timestamp = block ? block.timestamp : Math.floor(Date.now() / 1000);

    // 尝试获取合约 ABI（JSON array）
    let abiJson = [];
    try {
      const formatted = MetaNodeStakeFactory.interface.format("json");
      if (typeof formatted === "string") {
        // 常见情况：字符串化的 JSON 数组
        abiJson = JSON.parse(formatted);
      } else if (Array.isArray(formatted)) {
        // 有时直接就是数组
        abiJson = formatted;
      } else if (formatted) {
        // 兜底处理：把对象先序列化再解析为标准数组
        try {
          abiJson = JSON.parse(JSON.stringify(formatted));
        } catch {
          abiJson = [];
        }
      } else {
        abiJson = [];
      }
    } catch (e) {
      log(`获取 ABI 时出错，使用空 ABI 作为回退：${e.message}`);
      abiJson = [];
    }

    const cacheObj = {
      MetaNode: metaNodeDeployment.address,
      StakeToken: stakeTokenDeployment.address,
      MetaNodeStake: proxyAddress || null,
      network: netName,
      chainId: chainId,
      deployer: deployer,
      blockNumber: String(blockNumber),
      timestamp: timestamp,
      abi: abiJson
    };

    const cacheDir = path.join(__dirname, "..", "cache", "store");
    fs.mkdirSync(cacheDir, { recursive: true });
    const cachePath = path.join(cacheDir, `${netName}.json`);
    fs.writeFileSync(cachePath, JSON.stringify(cacheObj, null, 2), "utf8");
    log(`已将部署信息写入缓存：${cachePath}`);
  } catch (e) {
    log(`写入 cache/store/<network>.json 失败：${e.message}`);
  }
};

module.exports.tags = ["MetaNodeStake"];
