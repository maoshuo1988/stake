// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MetaNodeStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ************************************** INVARIANT **************************************

    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0;

    // ************************************** DATA STRUCTURE **************************************
    /*
    说明（奖励待领取的计算逻辑）：

    在任意时刻，一个用户应得但尚未实际发放的 MetaNode 数量（pending）由下列公式给出：

    pending MetaNode = (user.stAmount * pool.accMetaNodePerST) - user.finishedMetaNode

    在用户对某个池进行 deposit/unstake 等操作时，合约会按顺序完成以下步骤以保证奖励不会重复计算：
    1. 更新对应池的 accMetaNodePerST（以及 lastRewardBlock），即结算池级别的累计每份奖励。
    2. 把当前计算得到的 pending 奖励累加到用户的 pendingMetaNode（或直接发送，视具体函数而定）。
    3. 更新用户的 stAmount（增加或减少质押量）。
    4. 根据新的 accMetaNodePerST 计算并设置用户的 finishedMetaNode（新的结算基线），以避免重复计算历史奖励。

    EN: Basic explanation (original English):
    EN: Basically, at any point in time, the amount of MetaNodes entitled to a user but pending to be distributed is:
    EN:
    EN: pending MetaNode = (user.stAmount * pool.accMetaNodePerST) - user.finishedMetaNode
    EN:
    EN: Whenever a user deposits or withdraws staking tokens to a pool, here's what happens:
    EN: 1. The pool's `accMetaNodePerST` (and `lastRewardBlock`) gets updated.
    EN: 2. User receives the pending MetaNode sent to his/her address.
    EN: 3. User's `stAmount` gets updated.
    EN: 4. User's `finishedMetaNode` gets updated.
    */
    struct Pool {
        // 质押代币地址（若为 ETH 池，则为 address(0)）
        // Address of staking token
        // EN: Address of staking token (for ETH pool use address(0))
        address stTokenAddress;
        // Weight of pool
        // 池的权重（用于按比例分配 MetaNode 奖励）
        // EN: Pool weight used to calculate reward share among pools
        uint256 poolWeight;
        // Last block number that MetaNodes distribution occurs for pool
        // 上一次进行奖励分配结算的区块高度
        // EN: The last block number when rewards were distributed for this pool
        uint256 lastRewardBlock;
        // 每份质押（放大 1e18）累计获得的 MetaNode 数量
        // accMetaNodePerST = 累计每 1 单位质押自上次结算以来应分配的 MetaNode（乘以 1e18 以保留精度）
        // EN: Accumulated MetaNodes per staking token (scaled by 1e18 for precision)
        uint256 accMetaNodePerST;
        // Staking token amount
        // 池中当前被质押的代币总量（单位同 stToken）
        // EN: Total amount of staking tokens currently deposited in this pool
        uint256 stTokenAmount;
        // Min staking amount
        // 单笔最小质押数量（可为 0）
        // EN: Minimum deposit amount per single deposit (can be 0)
        uint256 minDepositAmount;
        // Withdraw locked blocks
        // 退押锁定的区块数（unstake 后需要等待的区块数才能 withdraw）
        // EN: Number of blocks a user must wait after unstake before withdraw becomes available
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 要提现的数量（用户提交的退押请求中的数量）
        // EN: Amount requested to withdraw in this unstake request
        uint256 amount;
        // 可提现的区块高度（在该区块高度或之后可以真正 withdraw）
        // EN: Block number when this request becomes withdrawable
        uint256 unlockBlocks;
    }

    struct User {
        // 用户在该池中的质押记录
        // 用户当前在池中质押的代币数量（不含未解锁的退押请求）
        // EN: Staking token amount the user currently has in the pool (excluding amounts in pending unstake requests)
        uint256 stAmount;
        // 用户已结算/作为基线的已计算到位的 MetaNode（用于避免重复计算 pending）
        // EN: The baseline amount of MetaNode already accounted for this user (used to avoid double counting)
        uint256 finishedMetaNode;
        // 用户当前待领取但尚未领取的 MetaNode（由历史操作累加）
        // EN: Pending MetaNode rewards that have been accumulated but not yet claimed
        uint256 pendingMetaNode;
        // 用户的退押请求队列（每条请求包含 amount 与 unlockBlocks）
        // EN: List of the user's unstake requests (each contains amount and unlockBlocks)
        UnstakeRequest[] requests;
    }

    // ************************************** STATE VARIABLES **************************************
    // First block that MetaNodeStake will start from
    // EN: The block number when staking rewards begin
    uint256 public startBlock; // 质押开始区块高度
    // First block that MetaNodeStake will end from
    // EN: The block number when staking rewards end
    uint256 public endBlock; // 质押结束区块高度
    // MetaNode token reward per block
    // EN: Number of MetaNode tokens distributed per block
    uint256 public MetaNodePerBlock; // 每个区块高度，MetaNode 的奖励数量

    // Pause the withdraw function
    // EN: Flag to indicate withdraw is paused
    bool public withdrawPaused; // 是否暂停提现
    // Pause the claim function
    // EN: Flag to indicate claim is paused
    bool public claimPaused; // 是否暂停领取

    // MetaNode token
    // EN: The MetaNode ERC20 token contract used for rewards
    IERC20 public MetaNode; // MetaNode 代币地址

    // Total pool weight / Sum of all pool weights
    // EN: Sum of all pool weights used to calculate distribution ratios
    uint256 public totalPoolWeight; // 所有资金池的权重总和
    // List of pools
    // EN: Array storing all pool definitions
    Pool[] public pool; // 资金池列表

    // pool id => user address => user info
    // EN: Mapping from pool id and user address to the corresponding User struct
    mapping(uint256 => mapping(address => User)) public user; // 资金池 id => 用户地址 => 用户信息

    // ************************************** EVENT **************************************

    event SetMetaNode(IERC20 indexed MetaNode);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetMetaNodePerBlock(uint256 indexed MetaNodePerBlock);

    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );

    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockedBlocks
    );

    event SetPoolWeight(
        uint256 indexed poolId,
        uint256 indexed poolWeight,
        uint256 totalPoolWeight
    );

    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalMetaNode
    );

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );

    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 MetaNodeReward
    );

    // ************************************** MODIFIER **************************************

    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }

    /**
     * @notice 初始化合约并设置基础参数（仅可调用一次，部署时使用）
     * @dev 主要完成 AccessControl/UUPS 权限初始化并设置 MetaNode 代币、起始/结束区块及每区块产出
     * EN: Initialize the contract and set basic parameters (callable once during deployment).
     * EN: This sets up AccessControl/UUPS roles and configures MetaNode token, start/end blocks and reward per block.
     */
    function initialize(
        IERC20 _MetaNode,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _MetaNodePerBlock
    ) public initializer {
        require(
            _startBlock <= _endBlock && _MetaNodePerBlock > 0,
            "invalid parameters"
        );

        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setMetaNode(_MetaNode);

        startBlock = _startBlock;
        endBlock = _endBlock;
        MetaNodePerBlock = _MetaNodePerBlock;
    }

    // 升级授权：仅拥有 UPGRADE_ROLE 的账户可以执行实现合约的升级
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}

    // ************************************** ADMIN FUNCTION **************************************

    /**
     * @notice 设置 MetaNode 代币地址（仅管理员可调用）
     * @dev 当需要变更发放代币合约地址时由管理员设置
     * EN: Set the MetaNode token contract address. Callable by admin only.
     */
    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;

        emit SetMetaNode(MetaNode);
    }

    /**
     * @notice 暂停 withdraw 操作（仅管理员可调用）
     * @dev 设置 withdrawPaused 标志为 true，以应对紧急情况或升级维护
     * EN: Pause withdraw operation. Callable by admin to set withdrawPaused flag to true.
     */
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    /**
     * @notice 恢复 withdraw 操作（仅管理员可调用）
     * EN: Unpause withdraw operation. Callable by admin.
     */
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw has been already unpaused");

        withdrawPaused = false;

        emit UnpauseWithdraw();
    }

    /**
     * @notice 暂停 claim（领取奖励）操作（仅管理员可调用）
     * EN: Pause claim operation (disable claiming rewards). Callable by admin.
     */
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");

        claimPaused = true;

        emit PauseClaim();
    }

    /**
     * @notice 恢复 claim（领取奖励）操作（仅管理员可调用）
     * EN: Unpause claim operation. Callable by admin.
     */
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has been already unpaused");

        claimPaused = false;

        emit UnpauseClaim();
    }

    /**
     * @notice 设置奖励计算的起始区块（仅管理员可调用）
     * @dev 要求 startBlock <= endBlock
     * EN: Update the start block for reward calculation. Callable by admin.
     */
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );

        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice 设置奖励计算的结束区块（仅管理员可调用）
     * @dev 要求 startBlock <= endBlock
     * EN: Update the end block for reward calculation. Callable by admin.
     */
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "start block must be smaller than end block"
        );

        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice 设置每个区块发放的 MetaNode 数量（仅管理员可调用）
     * @dev _MetaNodePerBlock 必须大于 0
     * EN: Update the amount of MetaNode tokens distributed per block. Callable by admin.
     */
    function setMetaNodePerBlock(
        uint256 _MetaNodePerBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(_MetaNodePerBlock > 0, "invalid parameter");

        MetaNodePerBlock = _MetaNodePerBlock;

        emit SetMetaNodePerBlock(_MetaNodePerBlock);
    }

    /**
     * @notice 添加一个新的质押池（仅管理员可调用）
     * @dev 注意：不要对同一 staking token 添加多个池，否则奖励分配会出错。
     * EN: Add a new staking pool. Callable by admin. Do not add the same staking token more than once.
     */
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        // 约定：第一个池为 ETH 池，使用 stTokenAddress = address(0)
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0x0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0x0),
                "invalid staking token address"
            );
        }
        // 允许最小质押数量为 0
        //require(_minDepositAmount > 0, "invalid min deposit amount");
        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

        if (_withUpdate) {
            massUpdatePools();
        }

        // 若当前区块已超过 startBlock，则从当前区块开始计奖，否则从 startBlock 开始
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;

        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockedBlocks
        );
    }

    /**
     * @notice 更新指定池的配置信息（minDepositAmount / unstakeLockedBlocks），仅管理员可调用
     * EN: Update the given pool's info (minDepositAmount and unstakeLockedBlocks). Callable by admin.
     */
    function updatePool(
        uint256 _pid,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新指定池的权重（poolWeight），可选择是否同时更新所有池（withUpdate），仅管理员可调用
     * EN: Update the given pool's weight. Optionally call massUpdatePools if withUpdate is true.
     */
    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");

        if (_withUpdate) {
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // ************************************** QUERY FUNCTION **************************************

    /**
     * @notice 获取当前池的数量
     * EN: Get the number of pools currently configured
     */
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /**
     * @notice 计算在 [_from, _to) 区间内应分配的 MetaNode 总量乘数（受 startBlock/endBlock 限制）
     * @param _from 起始区块（包含）
     * @param _to   结束区块（不包含）
     * @dev 返回值为 (_to - _from) * MetaNodePerBlock，且会把区间裁剪到 [startBlock, endBlock] 内
     * EN: Return reward multiplier over given _from to _to block. The value is (_to - _from) * MetaNodePerBlock.
     */
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block");
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        require(_from <= _to, "end block must be greater than start block");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(MetaNodePerBlock);
        require(success, "multiplier overflow");
    }

    /**
     * @notice 查询指定用户在池中截至当前区块的待领取 MetaNode 数量（包括已累积但未领取的部分）
     * EN: Get pending MetaNode amount of user in pool as of current block
     */
    function pendingMetaNode(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    /**
     * @notice 根据指定区块高度计算用户在该池的待领取奖励（该函数不会改变链上状态，仅作视图查询）
     * @param _pid 池 id
     * @param _user 用户地址
     * @param _blockNumber 用于计算的区块高度（该高度以下的奖励会被计入）
     * EN: Get pending MetaNode amount of user by a specific block number (view only)
     */
    function pendingMetaNodeByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool_.lastRewardBlock,
                _blockNumber
            );
            uint256 MetaNodeForPool = (multiplier * pool_.poolWeight) /
                totalPoolWeight;
            accMetaNodePerST =
                accMetaNodePerST +
                (MetaNodeForPool * (1 ether)) /
                stSupply;
        }

        return
            (user_.stAmount * accMetaNodePerST) /
            (1 ether) -
            user_.finishedMetaNode +
            user_.pendingMetaNode;
    }

    /**
     * @notice Get the staking amount of user
     * EN: Return the staking token amount that a user has deposited in a pool
     */
    function stakingBalance(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    /**
     * @notice Get the withdraw amount info, including the locked unstake amount and the unlocked unstake amount
     * EN: Return both total requested unstake amount and amount that is currently withdrawable
     */
    function withdrawAmount(
        uint256 _pid,
        address _user
    )
        public
        view
        checkPid(_pid)
        returns (uint256 requestAmount, uint256 pendingWithdrawAmount)
    {
        User storage user_ = user[_pid][_user];

        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawAmount =
                    pendingWithdrawAmount +
                    user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    // ************************************** PUBLIC FUNCTION **************************************

    /**
     * @notice 更新指定池的奖励变量，使其与当前区块保持同步
     * @dev 计算从 pool.lastRewardBlock 到当前区块产生的总奖励，并按池内质押量更新 accMetaNodePerST
     * EN: Update reward variables of the given pool to be up-to-date. Calculate rewards since lastRewardBlock
     * EN: and accumulate accMetaNodePerST accordingly.
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        if (block.number <= pool_.lastRewardBlock) {
            return;
        }

        (bool success1, uint256 totalMetaNode) = getMultiplier(
            pool_.lastRewardBlock,
            block.number
        ).tryMul(pool_.poolWeight);
        require(success1, "overflow");

        (success1, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success1, "overflow");

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            (bool success2, uint256 totalMetaNode_) = totalMetaNode.tryMul(
                1 ether
            );
            require(success2, "overflow");

            (success2, totalMetaNode_) = totalMetaNode_.tryDiv(stSupply);
            require(success2, "overflow");

            (bool success3, uint256 accMetaNodePerST) = pool_
                .accMetaNodePerST
                .tryAdd(totalMetaNode_);
            require(success3, "overflow");
            pool_.accMetaNodePerST = accMetaNodePerST;
        }

        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }

    /**
     * @notice 为所有池依次调用 updatePool（注意：当池数量较多时可能消耗大量 gas）
     */
    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }

    /**
     * @notice 向 ETH 池存入质押（直接发送 ETH），以换取 MetaNode 奖励
     * @dev 仅适用于 pool id = 0 的 ETH 池，函数为 payable 且会把 msg.value 视为质押数量
     * EN: Deposit staking ETH for MetaNode rewards. This function is payable and only for ETH pool (pid=0).
     */
    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];
        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        );

        uint256 _amount = msg.value;
        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is too small"
        );

        _deposit(ETH_PID, _amount);
    }

    /**
     * @notice 向指定 ERC20 池存入质押代币以获取 MetaNode 奖励
     * @dev 在调用前，用户需先在代币合约上 approve 本合约足够的额度
     * @param _pid 要存入的池子 id（不能为 0，0 为 ETH 池）
     * @param _amount 存入的代币数量
     * EN: Deposit staking token for MetaNode rewards. Before depositing, user needs to approve this contract.
     */
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support ETH staking");
        Pool storage pool_ = pool[_pid];
        require(
            _amount > pool_.minDepositAmount,
            "deposit amount is too small"
        );

        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        _deposit(_pid, _amount);
    }

    /**
     * @notice 提交退押请求（unstake），不会立即返回代币，而是生成一个需等待 unlockBlocks 的提现请求
     * @param _pid 要退押的池 id
     * @param _amount 要退押的代币数量（会从 user.stAmount 中扣减并加入 requests 队列）
     * EN: Unstake staking tokens. Generates a withdraw request which can be withdrawn after unlockBlocks.
     */
    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount >= _amount, "Not enough staking token balance");

        updatePool(_pid);

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether) -
            user_.finishedMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_;
        }

        if (_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unlockBlocks: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether);

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /**
     * @notice 提取已到达解锁条件的退押请求（withdraw），会把所有 unlockBlocks <= block.number 的请求合并并转账给用户
     * @param _pid 池 id
     * EN: Withdraw the unlocked unstake amounts. Merges all requests with unlockBlocks <= block.number and transfers funds.
     */
    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;
        uint256 popNum_;
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }

        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(
                    msg.sender,
                    pendingWithdraw_
                );
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    /**
     * @notice 领取指定池的 MetaNode 奖励（claim）。函数会先更新池状态，再计算并发放用户的 pending 奖励
     * @param _pid 要领取奖励的池 id
     * EN: Claim MetaNode tokens reward for a specific pool. Updates pool then transfers pending rewards.
     */
    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether) -
            user_.finishedMetaNode +
            user_.pendingMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = 0;
            _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
        }

        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether);

        emit Claim(msg.sender, _pid, pendingMetaNode_);
    }

    // ************************************** INTERNAL FUNCTION **************************************

    /**
     * @notice 内部函数：处理 deposit 的状态更新逻辑（不做转账操作）
     * @dev 执行流程：更新池状态 -> 结算用户未领取奖励并累加到 user.pendingMetaNode -> 更新 user.stAmount / pool.stTokenAmount -> 更新 user.finishedMetaNode
     * @param _pid 池 id
     * @param _amount 存入的代币数量（对 ETH 池而言由 depositETH 传入）
     * EN: Internal function to handle deposit logic: update pool, calculate pending rewards, update user and pool balances.
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        if (user_.stAmount > 0) {
            // uint256 accST = user_.stAmount.mulDiv(pool_.accMetaNodePerST, 1 ether);
            (bool success1, uint256 accST) = user_.stAmount.tryMul(
                pool_.accMetaNodePerST
            );
            require(success1, "user stAmount mul accMetaNodePerST overflow");
            (success1, accST) = accST.tryDiv(1 ether);
            require(success1, "accST div 1 ether overflow");

            (bool success2, uint256 pendingMetaNode_) = accST.trySub(
                user_.finishedMetaNode
            );
            require(success2, "accST sub finishedMetaNode overflow");

            if (pendingMetaNode_ > 0) {
                (bool success3, uint256 _pendingMetaNode) = user_
                    .pendingMetaNode
                    .tryAdd(pendingMetaNode_);
                require(success3, "user pendingMetaNode overflow");
                user_.pendingMetaNode = _pendingMetaNode;
            }
        }

        if (_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            require(success4, "user stAmount overflow");
            user_.stAmount = stAmount;
        }

        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(
            _amount
        );
        require(success5, "pool stTokenAmount overflow");
        pool_.stTokenAmount = stTokenAmount;

        // user_.finishedMetaNode = user_.stAmount.mulDiv(pool_.accMetaNodePerST, 1 ether);
        (bool success6, uint256 finishedMetaNode) = user_.stAmount.tryMul(
            pool_.accMetaNodePerST
        );
        require(success6, "user stAmount mul accMetaNodePerST overflow");

        (success6, finishedMetaNode) = finishedMetaNode.tryDiv(1 ether);
        require(success6, "finishedMetaNode div 1 ether overflow");

        user_.finishedMetaNode = finishedMetaNode;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice 安全的 MetaNode 转账函数：当合约余额不足以支付全部奖励时，只转出合约当前余额，避免 revert
     * @param _to 接收地址
     * @param _amount 期望转出的 MetaNode 数量
     * EN: Safe MetaNode transfer function, just in case if rounding error causes pool to not have enough MetaNodes.
     */
    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 MetaNodeBal = MetaNode.balanceOf(address(this));

        if (_amount > MetaNodeBal) {
            MetaNode.transfer(_to, MetaNodeBal);
        } else {
            MetaNode.transfer(_to, _amount);
        }
    }

    /**
     * @notice 安全的 ETH 转账函数（使用低级 call），在失败时 revert
     * @param _to 接收地址
     * @param _amount 转账的 ETH 数量（单位 wei）
     * EN: Safe ETH transfer function using low-level call; reverts on failure.
     */
    function _safeETHTransfer(address _to, uint256 _amount) internal {
        (bool success, bytes memory data) = address(_to).call{value: _amount}(
            ""
        );

        require(success, "ETH transfer call failed");
        if (data.length > 0) {
            require(
                abi.decode(data, (bool)),
                "ETH transfer operation did not succeed"
            );
        }
    }
}
