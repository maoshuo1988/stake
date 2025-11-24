# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a Hardhat Ignition module that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat ignition deploy ./ignition/modules/Lock.js
```


一、合约质押逻辑（技术实现要点）
- 主要数据结构
  - Pool：每个质押池记录质押代币地址（`stTokenAddress`）、权重（`poolWeight`）、上次奖励结算区块（`lastRewardBlock`）、每份质押累计奖励（`accMetaNodePerST`）、池内质押总量（`stTokenAmount`）、最小质押量、解质押锁定区块数等。
  - User：记录单个用户在某池的质押量（`stAmount`）、已结算到用户的奖励基线（`finishedMetaNode`）、未领取奖励缓存（`pendingMetaNode`）、以及一组未解锁的退押请求（`requests`）。
- 奖励计算核心
  - 使用“每质押单位累计奖励”模型：pool.accMetaNodePerST 表示“每 1 个质押代币自上次以来累计的 MetaNode 奖励（以 1 ether 作为放大系数）”。
  - pending = (user.stAmount * accMetaNodePerST) / 1e18 - user.finishedMetaNode + user.pendingMetaNode
  - 更新逻辑：updatePool 会基于 getMultiplier(lastRewardBlock, currentBlock) * poolWeight / totalPoolWeight 计算本池这段时间产生的总奖励，再除以池内质押量得到对 accMetaNodePerST 的增量。
  - pending（在仓库中通常为 user.pendingMetaNode）记录“已产生但尚未实际发放给用户”的奖励余额。
    计算公式（合约中常用）：
    pending = (user.stAmount * pool.accMetaNodePerST) / 1e18 - user.finishedMetaNode + user.pendingMetaNode
    其中 accMetaNodePerST 是每单位质押累计的奖励，finishedMetaNode 是用户已结算的基线。
    更新时机：每次 updatePool / _deposit / unstake 等会把按当前基线计算出的新增奖励累加到 user.pendingMetaNode，并更新 user.finishedMetaNode 以避免重复计入。
    发放（claim）时：合约会把 user.pendingMetaNode（加上当前未结算部分）清零并通过 _safeMetaNodeTransfer 尝试转币；若合约余额不足，只发剩余，未发部分会根据实现留在 pending（或在下一次计算中继续体现）。
    设计目的：避免每次产生奖励就立即转账（节省 gas、合并发放），防止重复计算（通过 finishedMetaNode 基线），并在合约不能即时全额支付时保留可领取余额以供后续处理。
    典型场景：用户多次 deposit/区块推进产生奖励 → pending 累积；用户调用 claim → 合约尝试把 pending 发给用户并清零（或按实际余额发放）。
- 存取款流程（内部函数）
  - deposit / depositETH -> 调用 _deposit：
    - 先 updatePool（拿到最新 accMetaNodePerST）
    - 计算并累加当前未结算的 pending（把未分配的奖励转入 user.pendingMetaNode）
    - 增加 user.stAmount、增加 pool.stTokenAmount
    - 更新 user.finishedMetaNode = user.stAmount * pool.accMetaNodePerST / 1e18（重置结算基线）
  - unstake：
    - 验证用户余额足够
    - updatePool，计算 pending 并累加到 user.pendingMetaNode
    - 扣减 user.stAmount 并在 user.requests 推入一条包含 unlockBlocks = block.number + pool.unstakeLockedBlocks 的退押请求（记录要退回的数量，延迟可提取）
    - pool.stTokenAmount -= _amount
    - 更新 user.finishedMetaNode
  - withdraw：
    - 遍历 user.requests，汇总所有 unlockBlocks <= block.number 的请求作为可提现的 pendingWithdraw_，删除处理后的请求记录（数组左移然后 pop）
    - 根据 pool.stTokenAddress 判断是直接以 ETH 转账还是 ERC20 safeTransfer
- 领取奖励（claim）：
  - updatePool 后，计算 pendingMetaNode_（同公式）
  - 如果 pending > 0，将 user.pendingMetaNode 置 0 并执行 _safeMetaNodeTransfer（合约向用户转 MetaNode 代币，若余额不足则只发放剩余）
  - 更新 user.finishedMetaNode 为当前基线
- 其他辅助
  - getMultiplier(_from, _to) 会把区块区间限制在 startBlock..endBlock 并计算区间内的 MetaNode 生成量（_to - _from） * MetaNodePerBlock
  - 管理员角色（ADMIN_ROLE）用于添加/更新池、pause/unpause 等

二、业务意义（为什么要有 staking）
- 激励与分配：通过给质押者发放代币（MetaNode），将代币分配给支持网络/产品的用户，形成参与激励。
- 锁定与稳健性：通过 unstake-lock（延迟提现）减少短期资金抽离，稳定质押池的总量，保护生态经济（减少套利/闪电抽走）。
- 权益证明（经济安全）：鼓励用户长期持有并参与治理或网络服务（若 MetaNode 与网络治理/服务相关）。
- 流动性与收益：将流动资产转化为持续收益来源，吸引资金进入生态。

三、业务流程（用户与管理员交互，按步骤）
- 管理员初始化与配置（one-time / 偶尔）
  1. 部署合约并调用 `initialize(MetaNodeToken, startBlock, endBlock, MetaNodePerBlock)`。
  2. 管理员添加池子 `addPool(stTokenAddress, poolWeight, minDepositAmount, unstakeLockedBlocks, withUpdate)`。第一个池为 ETH（address(0)），其后为 ERC20。
  3. （可选）调整 `setPoolWeight`, `updatePool` 或 `setMetaNodePerBlock`, `setStartBlock`, `setEndBlock` 等。
- 用户流程（典型）
  1. 用户为 ERC20 池：先调用 `ERC20.approve(contract, amount)`；对 ETH 池则直接发送 ETH。
  2. 调用 `deposit(pid, amount)` 或 `depositETH()` 将资金质押到某池；合约内部记录用户 stAmount 并更新奖励结算基线。
  3. 随着区块推进，用户在任何时刻可通过 `pendingMetaNode(pid, user)` 查询可领奖励；也可直接 `claim(pid)` 来领取奖励（会触发 updatePool 并把奖励转给用户）。
  4. 若要退出质押，用户调用 `unstake(pid, amount)`：实际会把这笔 amount 标记为 withdraw 请求并在 n 个锁定区块之后可提取（unlockBlocks）；该请求不会立刻把代币返还，只是生成请求。
  5. 在锁定期到后用户调用 `withdraw(pid)` 来收回已解锁的提现请求（合约会把 ETH 或 ERC20 转回用户）。
- 管理员控制
  - 管理员可暂停 `claim` 或 `withdraw`（`pauseClaim` / `pauseWithdraw`），用于应对紧急情况或升级。
  - 管理员也可更新池参数或调整奖励率以实现治理目标。

四、业务与技术上的注意点 / 风险与缓解
- 奖励不足风险：合约在发放奖励时并不会从头检查合约 MetaNode 余额，`_safeMetaNodeTransfer` 会按剩余余额发放，可能导致短期内不能全额发放 -> 需在运营上保证合约有足够代币或实现流动性补足策略。
- 竞争/顺序问题：updatePool 会按照区块计算奖励，若多个池存在权重差异，短时间内池权重变动会改变奖励分配，需要管理者谨慎调整 `totalPoolWeight`。
- 精度和溢出：合约使用 1 ether 放大 accMetaNodePerST，Math.tryMul / tryDiv 用于避免溢出；但在实现中需要确保所有运算都检查返回值（合约已这么做）。测试应覆盖极端数值场景。
- 退押请求数组 gas 成本：withdraw 内对请求数组做左移并 pop 的实现，在请求很多时会消耗较多 gas，需在业务上限制用户请求频率或合并请求以降低 gas。
- 权限与升级：合约使用 AccessControl 和 UUPS 升级模式，需保护 UPGRADE_ROLE/ADMIN_ROLE 的私钥，并在升级前做好审计和迁移计划。
- 时间同步与区块高度依赖：逻辑依赖区块高度（非时间戳），在测试/模拟中需要正确推进区块。如果把 startBlock/endBlock 设置得非常近，可能使奖励窗口意外变小。
- 其他恶意路径：重入（合约使用 OpenZeppelin 的 safeTransfer / transfer，可减少风险）、整数边界检查（合约使用 tryMath）等。

五、测试建议（覆盖业务流程与边界）
- 功能性测试
  - 初始化参数与权限（非管理员调用应被拒绝）
  - 添加池（首池必须为 ETH，重复添加 ETH 被拒绝）
  - deposit/unstake/withdraw/claim 的正常路径
  - pendingMetaNode 与 claim 前后余额变化
- 边界测试
  - 奖励超出合约持有余额（MetaNode 余额不足时只发放剩余）
  - 多个用户同时质押、不同权重池下的奖励分配公平性（数学正确性）
  - 大数值测试（极大的质押量、极高奖励速率）以触发 overflow 分支（expect revert）
  - 退押请求数组大量请求时 withdraw 的行为和 gas（模拟合并或多请求）
- 安全测试
  - 暂停逻辑（pause/unpause）和权限检查
  - 升级与权限安全（确保只有 UPGRADE_ROLE 可以升级）
  - 重入与回退路径（模拟稀有交易 revert 情况）

六、简短总结（可放进产品文档）
- 这个合约实现了一个基于区块奖励、按池权重分配的质押奖励系统：用户质押资产换取 MetaNode 奖励，且通过“每单位质押累计奖励”模型保证奖励按比例正确分配；退押分为请求和提现两步以实现锁定期；管理员控制整体经济参数并可暂停关键功能。该模式适合用于代币经济中向长期支持者分配治理/服务代币，同时通过锁定期和权重机制平衡激励与稳健性。

现在我将标记任务 1 完成，并把任务 2 标为进行中，接着会写“业务意义”与“业务流程”任务（这些已包含在上文并会标记完成）。 我会把合约质押逻辑、业务意义与业务流程用要点形式给出，便于放到文档或产品说明中；下面以清晰、可复制的段落说明。

一、质押逻辑（实现要点）
- 数据模型
  - Pool：stTokenAddress、poolWeight、lastRewardBlock、accMetaNodePerST（放大 1e18）、stTokenAmount、minDepositAmount、unstakeLockedBlocks。
  - User：stAmount、finishedMetaNode（用户已结算基线）、pendingMetaNode（已累计但未领取）、requests（未解锁的退押请求数组）。
- 奖励计算（核心公式）
  - accMetaNodePerST 随时间累积，表示“每 1 单位质押的累计奖励（放大 1e18）”。
  - pendingMetaNode = (user.stAmount * accMetaNodePerST) / 1e18 - user.finishedMetaNode + user.pendingMetaNode
- 状态更新流程
  - updatePool(pid)：计算从 pool.lastRewardBlock 到当前区块的奖励份额（按 poolWeight / totalPoolWeight 分配），将其转为每单位质押的增量并累加到 accMetaNodePerST，然后把 pool.lastRewardBlock = block.number。
  - deposit/_deposit：先 updatePool，计算并累加未结算奖励到 user.pendingMetaNode，增加 user.stAmount 与 pool.stTokenAmount，更新 user.finishedMetaNode 为新的基线。
  - unstake：先校验余额并 updatePool，计算并累加 pendingMetaNode，减少 user.stAmount、在 user.requests 中加入一条 unlockBlocks = block.number + pool.unstakeLockedBlocks 的请求，减少 pool.stTokenAmount，更新 finishedMetaNode。
  - withdraw：扫描 user.requests，把 unlockBlocks <= block.number 的请求汇总为可提现金额，然后删除这些请求并将资金以 ETH 或 ERC20 形式转回用户。
  - claim：updatePool 后计算 pendingMetaNode，如果大于 0 则清空 user.pendingMetaNode 并执行代币转移（_safeMetaNodeTransfer），再更新 finishedMetaNode。
- 辅助机制
  - getMultiplier：把区块区间限制在 startBlock..endBlock，并计算区间内产出的 MetaNode 数量（(_to - _from) * MetaNodePerBlock），使用 tryMul/tryDiv 等防溢出检查。
  - 管理员/权限：使用 AccessControl，ADMIN_ROLE 控制 addPool/updatePool/pause 等；UPGRADE_ROLE 控制合约升级。

二、业务意义（为什么使用质押）
- 激励分配：把原生代币或奖励代币分配给对生态有贡献或提供资金的用户，促进参与和长期持有。
- 经济稳定性：通过池权重和退押锁定机制（unstakeLockedBlocks）平衡短期套利与长期稳定，降低突发性资金抽离造成的波动。
- 网络治理或服务保障：质押者可能具有治理权或能享受网络服务，质押作为门槛确保参与者的利益与网络一致。
- 吸引与留存：持续奖励为用户提供持续收益，提升平台对资本的吸引力。

三、业务流程（面向用户与管理员）
- 管理员流程（部署与配置）
  1. 部署合约并初始化：initialize(MetaNodeToken, startBlock, endBlock, MetaNodePerBlock)。
  2. 添加池子：addPool(stTokenAddress, poolWeight, minDepositAmount, unstakeLockedBlocks, withUpdate)。约定首池为 ETH（address(0)）。
  3. 可选：调整 pool 权重 setPoolWeight、修改 start/end 或 MetaNodePerBlock。
  4. 管理暂停：在紧急或维护时调用 pauseClaim/pauseWithdraw 并在完成后 unpause。
- 普通用户流程（质押与退出）
  1. ERC20 池：先在代币合约 approve 本合约；ETH 池直接通过 send ETH。
  2. deposit(pid, amount) 或 depositETH()：把资产质押到某池，合约会把用户的 stAmount 增加并在内部重置奖励结算基线。
  3. 查看 pending：调用 pendingMetaNode(pid, user) 查看可领奖励，或定期 claim(pid) 领取奖励。
  4. 退出：调用 unstake(pid, amount) 产生带锁定期的请求（unlockBlocks = currentBlock + unstakeLockedBlocks）；待到达 unlockBlocks 后调用 withdraw(pid) 来实际收回资产。
- 重要提示
  - 领取奖励和提现可被管理员临时暂停（pause），需注意用户沟通与紧急应对。
  - 合约发放奖励取决于合约持有的 MetaNode 余额（_safeMetaNodeTransfer 会按余额发放），运营应确保合约有足够奖励储备。

四、风险点与对应缓解建议
- 奖励不足：运营端需保证合约有足够的 MetaNode；或在发放策略上做排队/补发机制。
- 大量退押请求导致高 gas：建议合并请求或限制请求频次，或在 withdraw 中做分页/合并减低单笔 gas。
- 权限风险：严格保护 ADMIN_ROLE/UPGRADE_ROLE 私钥，必要时多签或时间锁管理关键操作。
- 溢出/精度问题：已使用放大系数 1e18 与 Math.tryMul/tryDiv，但仍建议在极端参数下写单元测试验证边界行为。
- 时间相关风险：startBlock/endBlock 过短会影响奖励窗口，务必测试在不同区块高度下的行为。

五、推荐的关键测试场景（简明）
- 初始化与权限（非管理员拒绝的操作）
- addPool 首池为 ETH，重复添加 ETH 被拒绝
- depositETH/deposit(ERC20) 的最小存款检查与正常路径
- pendingMetaNode 在不同区块高度的正确性（多用户在不同池内）
- claim 把 reward 转给用户（包含合约余额不足场景）
- unstake -> withdraw 的锁定与解锁流程，数组边界/删除行为
- pause/unpause 的生效验证
- 极端数值测试（大数、Pack overflow 预期 revert）

简短总结
- 该合约采用“每单位质押累计奖励”模型，能精确按比例分配奖励，支持 ETH 与 ERC20 池，提供延迟提现以稳定资金并使用管理员角色管理关键参数。业务上用于激励、锁定和治理门槛，实施时需关注奖励资金充足性、权限管理和 gas 成本。

---

## 运行测试与覆盖率

本仓库使用 Hardhat + solidity-coverage。下面是在本地（VSCode 的 cmd 终端）运行测试与生成覆盖率的推荐命令：

1. 安装依赖（如果尚未安装）：

```
npm install
```

2. 运行常规测试（显示堆栈跟踪）：

```
npx hardhat test --show-stack-traces
```

3. 仅运行管理员缓存相关测试（快速执行）：

```
npx hardhat test test/MetaNodeStake.admin.test.js --show-stack-traces
```

4. 生成覆盖率报告（Hardhat 插件）：

```
npx hardhat coverage
```

注意：admin 测试会尝试从 `cache/store/<network>.json` 读取部署信息并在本地环境通过 `hardhat_impersonateAccount` 模拟管理员账号。请确保 `cache/store/sepolia.json` 存在或运行过本地部署脚本生成对应 cache 文件。

如果在运行中遇到 impersonation 或资金不足错误，请确保本地 hardhat 节点允许 `hardhat_impersonateAccount` 并为被模拟账户转入少量 test ETH（脚本会尝试自动转入 1 ETH）。