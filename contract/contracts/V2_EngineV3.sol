// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UD60x18, ud, unwrap} from "@prb/math/src/UD60x18.sol";
import {SD59x18, sd, unwrap} from "@prb/math/src/SD59x18.sol";
import "@arbitrum/nitro-contracts/src/precompiles/ArbSys.sol";
import {getIPFSCID} from "./libraries/IPFS.sol";
import "./interfaces/IBaseToken.sol";

uint256 constant STARTING_ENGINE_TOKEN_AMOUNT = 600_000e18;
uint256 constant BASE_TOKEN_STARTING_REWARD = 1e18;

uint256 constant ARBITRUM_NOVA_CHAINID = 0xa4ba;
uint256 constant ARBITRUM_GOERLI_CHAINID = 0x66eed;
uint256 constant ARBITRUM_SEPOLIA_CHAINID = 0x66eee;
// https://github.com/OffchainLabs/arbitrum-classic/blob/master/docs/sol_contract_docs/md_docs/arb-os/arbos/builtin/ArbSys.md
address constant ARBSYS_ADDRESS = address(100);

// each run of model allocated fee to token address
struct Model {
    uint256 fee;
    address addr;
    uint256 rate;
    bytes cid;
}

struct Validator {
    uint256 staked; // tokens staked
    uint256 since; // when validator became validator
    address addr; // validator address
}

struct PendingValidatorWithdrawRequest {
    uint256 unlockTime;
    uint256 amount;
}

struct Task {
    bytes32 model; // model hash
    uint256 fee; // fee offered for completion on top of model base fee
    address owner; // who is allowed to retract
    uint64 blocktime;
    uint8 version; // task version
    bytes cid; // ipfs cid
}

struct Solution {
    address validator;
    uint64 blocktime;
    bool claimed;
    bytes cid; // ipfs cid
}

struct Contestation {
    address validator;
    uint64 blocktime;
    uint32 finish_start_index; // used for finish claiming of rewards
    uint256 slashAmount; // amount to slash
}

contract V2_EngineV3 is OwnableUpgradeable {
    IBaseToken public baseToken;

    address public treasury; // where treasury fees/rewards go

    address public pauser; // who can pause contract

    bool public paused; // if contract is paused

    uint256 public accruedFees; // fees in baseToken accrued to treasury

    bytes32 public prevhash; // previous task hash, used to provide entropy for next task hash

    uint64 public startBlockTime; // when this was initialized

    uint256 public version; // version (should be updated when performing updates)

    uint256 public validatorMinimumPercentage; // how much a validator needs to stay a validator (of total supply)

    uint256 public slashAmountPercentage; // how much validator should lose on failed vote (of total supply)

    uint256 public solutionFeePercentage; // How much of task fee for solutions go to treasury

    uint256 public retractionFeePercentage; // How much to charge users for retracting tasks (goes to treasury)

    uint256 public treasuryRewardPercentage; // How much of task reward to send to treasury

    uint256 public minClaimSolutionTime; // how long a solver must wait to claim solution

    uint256 public minRetractionWaitTime; // how long to wait without solution to retract

    uint256 public minContestationVotePeriodTime; // how long voting period should last
    uint256 public maxContestationValidatorStakeSince; // delay for validator "since" property after which a validator may no longer vote on a contestation

    uint256 public exitValidatorMinUnlockTime; // how long it takes for a validator to wait to unstake

    // model hash -> model
    mapping(bytes32 => Model) public models;

    mapping(address => Validator) public validators;

    // address -> counter
    mapping(address => uint256) public pendingValidatorWithdrawRequestsCount;

    // address -> counter -> PendingValidatorWithdrawRequest
    mapping(address => mapping(uint256 => PendingValidatorWithdrawRequest))
        public pendingValidatorWithdrawRequests;

    // address -> amount pending withdraw
    // this should be subtracted from validators[].staked for usable balance
    mapping(address => uint256) public validatorWithdrawPendingAmount;

    // task hash -> task
    mapping(bytes32 => Task) public tasks;

    // commitment
    // keccak256(abi.encode(msg.sender, taskid_, cid_)) -> block.number (or arbBlockNumber)
    mapping(bytes32 => uint256) public commitments;

    // task hash -> solution
    mapping(bytes32 => Solution) public solutions;

    // task hash -> contestation
    mapping(bytes32 => Contestation) public contestations;

    mapping(bytes32 => mapping(address => bool)) public contestationVoted;
    mapping(bytes32 => uint256) public contestationVotedIndex;
    mapping(bytes32 => address[]) public contestationVoteYeas;
    mapping(bytes32 => address[]) public contestationVoteNays;

    mapping(bytes32 => uint256) public solutionsStake; // v2
    uint256 public solutionsStakeAmount; // v2
    mapping(address => uint256) public lastContestationLossTime; // v2

    uint256 public totalHeld; // v3
    uint256 public solutionRateLimit; // v3
    mapping(address => uint256) public lastSolutionSubmission; // v3
    uint256 public taskOwnerRewardPercentage; // v3
    uint256 public contestationVoteExtensionTime; // v3

    uint256[40] __gap; // upgradeable gap

    event ModelRegistered(bytes32 indexed id);

    event ValidatorDeposit(
        address indexed addr,
        address indexed validator,
        uint256 amount
    );
    event ValidatorWithdrawInitiated(
        address indexed addr,
        uint256 indexed count,
        uint256 unlockTime,
        uint256 amount
    );
    event ValidatorWithdrawCancelled(
        address indexed addr,
        uint256 indexed count
    );
    event ValidatorWithdraw(
        address indexed addr,
        address indexed to,
        uint256 indexed count,
        uint256 amount
    );

    event TaskSubmitted(
        bytes32 indexed id,
        bytes32 indexed model,
        uint256 fee,
        address indexed sender
    );
    event SignalCommitment(address indexed addr, bytes32 indexed commitment);
    event SolutionSubmitted(address indexed addr, bytes32 indexed task);
    event SolutionClaimed(address indexed addr, bytes32 indexed task);
    event ContestationSubmitted(address indexed addr, bytes32 indexed task);
    event ContestationVote(
        address indexed addr,
        bytes32 indexed task,
        bool yea
    );
    event ContestationVoteFinish(
        bytes32 indexed id,
        uint32 indexed start_idx,
        uint32 end_idx
    );

    event TreasuryTransferred(address indexed to);
    event PauserTransferred(address indexed to);
    event PausedChanged(bool indexed paused);
    event SolutionMineableRateChange(bytes32 indexed id, uint256 rate);
    event VersionChanged(uint256 version);
    event StartBlockTimeChanged(uint64 indexed startBlockTime); // v2

    /// @notice Modifier to restrict to only pauser
    modifier onlyPauser() {
        require(msg.sender == pauser, "not pauser");
        _;
    }

    /// @notice Modifier to restrict to only not paused
    modifier notPaused() {
        require(!paused, "paused");
        _;
    }

    /// @notice Check if address is a validator
    /// @param addr Address to check
    /// @return Whether address is a validator
    function _onlyValidator(address addr) internal view returns (bool) {
        return validators[addr].staked -
                validatorWithdrawPendingAmount[addr] >=
                getValidatorMinimum();
    }

    /// @notice Modifier to restrict to only validators
    modifier onlyValidator() {
        require(_onlyValidator(msg.sender), "min staked too low");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize contract
    /// @dev For upgradeable contracts this function necessary
    function initialize() public reinitializer(3) {
        minClaimSolutionTime = 3600; // 60 minutes
        minContestationVotePeriodTime = 360; // 6 minutes
        exitValidatorMinUnlockTime = 259200; // 3 days
        solutionRateLimit = 1 ether; // 1 second required between solution submissions
        taskOwnerRewardPercentage = 0.1 ether; // 10%
        contestationVoteExtensionTime = 10; // 10 seconds
    }

    /// @notice Transfer ownership
    /// @param to_ Address to transfer ownership to
    function transferOwnership(
        address to_
    ) public override(OwnableUpgradeable) onlyOwner {
        super.transferOwnership(to_);
    }

    /// @notice Transfer treasury
    /// @param to_ Address to transfer treasury to
    function transferTreasury(address to_) external onlyOwner {
        treasury = to_;
        emit TreasuryTransferred(to_);
    }

    /// @notice Transfer ownership
    /// @param to_ Address to transfer pauser to
    function transferPauser(address to_) external onlyOwner {
        pauser = to_;
        emit PauserTransferred(to_);
    }

    /// @notice Pause/unpause contract
    /// @param paused_ Whether to pause or unpause
    function setPaused(bool paused_) external onlyPauser {
        paused = paused_;
        emit PausedChanged(paused_);
    }

    /// @notice Set solution mineable rate
    /// @param model_ Model hash
    /// @param rate_ Rate of model
    function setSolutionMineableRate(
        bytes32 model_,
        uint256 rate_
    ) external onlyOwner {
        require(models[model_].addr != address(0x0), "model does not exist");
        models[model_].rate = rate_;
        emit SolutionMineableRateChange(model_, rate_);
    }

    /// @notice Set version
    /// @param version_ Version of contract
    /// @dev This is used for upgrades to inform miners of changes
    function setVersion(uint256 version_) external onlyOwner {
        version = version_;
        emit VersionChanged(version_);
    }

    /// @notice Set start block time
    /// @dev introduced in v2
    /// @param startBlockTime_ Start block time
    function setStartBlockTime(uint64 startBlockTime_) external onlyOwner {
        startBlockTime = startBlockTime_;
        emit StartBlockTimeChanged(startBlockTime_);
    }

    /// @notice Get slash amount
    /// @return Slash amount
    function getSlashAmount() public view returns (uint256) {
        uint256 ts = getPsuedoTotalSupply();
        return ts - ((ts * (1e18 - slashAmountPercentage)) / 1e18);
    }

    /// @notice Get validator minimum staked
    /// @return Validator minimum staked
    function getValidatorMinimum() public view returns (uint256) {
        uint256 ts = getPsuedoTotalSupply();
        return ts - ((ts * (1e18 - validatorMinimumPercentage)) / 1e18);
    }

    /// @notice Get IPFS cid
    /// @dev use this for testing
    /// @param content_ Content to get IPFS cid of
    /// @return
    function generateIPFSCID(
        bytes calldata content_
    ) external pure returns (bytes memory) {
        return getIPFSCID(content_);
    }

    /// @notice Hash model
    /// @param o_ Model to hash
    /// @param sender_ Address of sender
    /// @return hash of model
    function hashModel(
        Model memory o_,
        address sender_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(sender_, o_.addr, o_.fee, o_.cid));
    }

    /// @notice Hash task
    /// @param o_ Task to hash
    /// @param sender_ Address of sender
    /// @param prevhash_ Previous hash
    /// @return hash of task
    function hashTask(
        Task memory o_,
        address sender_,
        bytes32 prevhash_
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encode(sender_, prevhash_, o_.model, o_.fee, o_.cid));
    }

    /// @notice Target total supply
    /// @param t Time since beginning
    /// @return Target total supply
    function targetTs(uint256 t) public pure returns (uint256) {
        // require(t > 0, "min vals"); // NOT NEEDED as targetTs(0) = 0
        // ms * (1 - 1 / 2 ** (t/(60*60*24*365)))
        // target is max
        if (t > 3153600000) {
            return STARTING_ENGINE_TOKEN_AMOUNT;
        }
        // v3, factor of 2 emission reduction every year
        uint256 e = unwrap(ud(t).div(ud(2 * 60 * 60 * 24 * 365)).exp2());
        return
            STARTING_ENGINE_TOKEN_AMOUNT -
            ((STARTING_ENGINE_TOKEN_AMOUNT * 1e18 * 1e18) / e / 1e18);
    }

    /// @notice Difficulty multiplier
    /** @dev
    1 = 1e18
    lower value is higher difficulty / reduction of rewards
    */
    /// @param t Time since beginning
    /// @param ts Total supply
    /// @return Difficulty multiplier
    function diffMul(uint256 t, uint256 ts) public pure returns (uint256) {
        require(t > 0 && ts > 0, "min vals");

        // e = target_ts(t)
        uint256 e = targetTs(t);

        // d = ts / e
        SD59x18 d = sd(int256(ts)).div(sd(int256(e)));

        // prevents positive multiplier going to infinity
        // v3: 0.867 is inflection point where any lower will be > 100
        if (unwrap(d) < 867122876204505600) {
            return 100e18;
        }

        // helpers
        SD59x18 one = sd(1e18);
        SD59x18 onehundred = sd(100e18);

        // (1+((d-1)*100))-1
        // v3, factor of 2 emission reduction every year
        SD59x18 c = one.add((d.sub(one).mul(onehundred)).sub(one)).div(sd(2e18));

        // prevents negative multiplier overflow
        // TODO: Recompute this factor from overflow
        if (unwrap(c) >= 20e18) {
            return 0;
        }

        // 0.5 ^ c
        if (c.lt(sd(0))) {
            return uint256(unwrap(c.abs().exp2()));
        } else {
            return uint256(unwrap(one.div(c.exp2())));
        }
    }

    /// @notice Reward
    /// @param t Time since beginning
    /// @param ts Total supply
    /// @return Reward
    function reward(uint256 t, uint256 ts) public pure returns (uint256) {
        // we have a basic reward if for some reason our total supply is 0
        // this can happen if engine has a balance of 600k or more
        if (ts == 0) {
            return BASE_TOKEN_STARTING_REWARD;
        }

        return
            (((STARTING_ENGINE_TOKEN_AMOUNT - ts) *
                BASE_TOKEN_STARTING_REWARD) * diffMul(t, ts)) /
            STARTING_ENGINE_TOKEN_AMOUNT /
            1e18;
    }

    /// @notice Because we are using a token which is fully minted upfront we must calculate total supply based on the amount remaining in Engine
    /// @dev We return 0 rather than use require to avoid breaking the contract if bridged assets are sent to this contract before many tokens are mined
    /// @return Total supply of Engine tokens
    function getPsuedoTotalSupply() public view returns (uint256) {
        uint256 b = baseToken.balanceOf(address(this)) - totalHeld;
        if (b >= STARTING_ENGINE_TOKEN_AMOUNT) {
            return 0;
        }
        return STARTING_ENGINE_TOKEN_AMOUNT - b;
    }

    /// @notice Calculates the reward for current timestamp/supply
    /// @return Reward amount
    function getReward() public view returns (uint256) {
        return reward(block.timestamp - startBlockTime, getPsuedoTotalSupply());
    }

    /// @notice Generates commitment hash for a given task
    /// @return Commitment hash
    function generateCommitment(
        address sender_,
        bytes32 taskid_,
        bytes calldata cid_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(sender_, taskid_, cid_));
    }

    /// @notice Withdraws fees accrued to treasury
    /// @dev this exists to save on gas, no need for an additional transfer every task
    function withdrawAccruedFees() external notPaused {
        baseToken.transfer(treasury, accruedFees);
        totalHeld -= accruedFees; // v3
        accruedFees = 0;
    }

    /// @notice Registers a new model
    /// @param addr_ Address of model for accruing fees
    /// @param fee_ Base fee for model
    /// @param template_ data of template
    /// @return Model hash
    function registerModel(
        address addr_,
        uint256 fee_,
        bytes calldata template_
    ) external notPaused returns (bytes32) {
        require(addr_ != address(0x0), "address must be non-zero");

        bytes memory cid = getIPFSCID(template_);

        Model memory m = Model({addr: addr_, fee: fee_, cid: cid, rate: 0});

        bytes32 id = hashModel(m, msg.sender);
        require(models[id].addr == address(0x0), "model already registered");
        models[id] = m;

        emit ModelRegistered(id);

        return id;
    }

    /// @notice Deposit tokens to become a validator
    /// @dev anyone can top up a validators balance
    /// @param validator_ Address of validator
    /// @param amount_ Amount of tokens to deposit
    function validatorDeposit(
        address validator_,
        uint256 amount_
    ) external notPaused {
        baseToken.transferFrom(msg.sender, address(this), amount_);
        totalHeld += amount_; // v3

        // this will be 0 before MIN_SUPPLY_FOR_VALIDATOR_DEPOSITS
        uint256 min = getValidatorMinimum();

        // we update if validator is not staked enough and reaches minimum in this deposit
        if (validators[validator_].staked <= min) {
            if (validators[validator_].staked + amount_ >= min) {
                validators[validator_].since = block.timestamp;
            }
        }

        validators[validator_] = Validator({
            addr: validator_,
            since: validators[validator_].since,
            staked: validators[validator_].staked + amount_
        });

        emit ValidatorDeposit(msg.sender, validator_, amount_);
    }

    /// @notice Prepare to withdraw tokens (as a validator)
    /// @dev this is a 2 step process
    /// @param amount_ Amount of tokens to withdraw
    /// @return Counter for withdraw request
    function initiateValidatorWithdraw(
        uint256 amount_
    ) external notPaused returns (uint256) {
        require(
            validators[msg.sender].staked -
                validatorWithdrawPendingAmount[msg.sender] >=
                amount_,
            ""
        );

        uint256 unlockTime = block.timestamp + exitValidatorMinUnlockTime;

        pendingValidatorWithdrawRequestsCount[msg.sender] += 1;
        uint256 count = pendingValidatorWithdrawRequestsCount[msg.sender];

        pendingValidatorWithdrawRequests[msg.sender][
            count
        ] = PendingValidatorWithdrawRequest({
            unlockTime: unlockTime,
            amount: amount_
        });

        validatorWithdrawPendingAmount[msg.sender] += amount_;

        emit ValidatorWithdrawInitiated(msg.sender, count, unlockTime, amount_);
        return count;
    }

    /// @notice Cancel a pending withdraw request
    /// @param count_ Counter of withdraw request
    function cancelValidatorWithdraw(uint256 count_) external notPaused {
        PendingValidatorWithdrawRequest
            memory req = pendingValidatorWithdrawRequests[msg.sender][count_];
        require(req.unlockTime > 0, "request not exist");

        validatorWithdrawPendingAmount[msg.sender] -= req.amount;
        delete pendingValidatorWithdrawRequests[msg.sender][count_];

        emit ValidatorWithdrawCancelled(msg.sender, count_);
    }

    /// @notice Withdraw tokens (as a validator)
    /// @param count_ Counter of withdraw request
    /// @param to_ Address to send tokens to
    function validatorWithdraw(uint256 count_, address to_) external notPaused {
        PendingValidatorWithdrawRequest
            memory req = pendingValidatorWithdrawRequests[msg.sender][count_];

        require(req.unlockTime > 0, "request not exist");
        require(block.timestamp >= req.unlockTime, "wait longer");
        require(
            validators[msg.sender].staked >= req.amount,
            "stake insufficient"
        );

        baseToken.transfer(to_, req.amount);
        validators[msg.sender].staked -= req.amount;
        totalHeld -= req.amount; // v3
        validatorWithdrawPendingAmount[msg.sender] -= req.amount;

        delete pendingValidatorWithdrawRequests[msg.sender][count_];

        emit ValidatorWithdraw(msg.sender, to_, count_, req.amount);
    }

    /// @notice Add a task
    /// @param version_ Version of task
    /// @param owner_ Address of task owner
    /// @param model_ Model hash
    /// @param fee_ Fee for task
    /// @param cid_ IPFS cid of task
    function addTask(
        uint8 version_,
        address owner_,
        bytes32 model_,
        uint256 fee_,
        bytes memory cid_
    ) internal {
        Task memory task = Task({
            version: version_,
            owner: owner_,
            model: model_,
            blocktime: uint64(block.timestamp),
            fee: fee_,
            cid: cid_
        });
        bytes32 id = hashTask(task, msg.sender, prevhash);
        tasks[id] = task;
        emit TaskSubmitted(id, model_, fee_, msg.sender);
        prevhash = id;
    }

    /// @notice Submit a task
    /// @param version_ Version of task
    /// @param owner_ Address of task owner
    /// @param model_ Model hash
    /// @param fee_ Fee for task
    /// @param input_ Input data for task
    function submitTask(
        uint8 version_,
        address owner_,
        bytes32 model_,
        uint256 fee_,
        bytes calldata input_
    ) external notPaused {
        require(models[model_].addr != address(0x0), "model does not exist");
        require(fee_ >= models[model_].fee, "lower fee than model fee");

        bytes memory cid = getIPFSCID(input_);

        addTask(version_, owner_, model_, fee_, cid);

        baseToken.transferFrom(msg.sender, address(this), fee_);
        totalHeld += fee_; // v3
    }

    /// @notice Bulk submit tasks
    /// @dev Added in v3
    /// @param version_ Version of task
    /// @param owner_ Address of task owner
    /// @param model_ Model hash
    /// @param fee_ Fee for task
    /// @param input_ Input data for task
    /// @param n_ Number of tasks to submit
    function bulkSubmitTask(
        uint8 version_,
        address owner_,
        bytes32 model_,
        uint256 fee_,
        bytes calldata input_,
        uint256 n_
    ) external notPaused {
        require(models[model_].addr != address(0x0), "model does not exist");
        require(fee_ >= models[model_].fee, "lower fee than model fee");

        bytes memory cid = getIPFSCID(input_);

        for (uint256 i = 0; i < n_; ++i) {
            addTask(version_, owner_, model_, fee_, cid);
        }

        baseToken.transferFrom(msg.sender, address(this), fee_*n_);
        totalHeld += fee_*n_; // v3
    }

    /// @notice Get block number (on both arbitrum and l1)
    /// @return Block number
    function getBlockNumberNow() internal view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }

        if (
            id == ARBITRUM_NOVA_CHAINID ||
            id == ARBITRUM_GOERLI_CHAINID ||
            id == ARBITRUM_SEPOLIA_CHAINID
        ) {
            return ArbSys(ARBSYS_ADDRESS).arbBlockNumber();
        }

        return block.number;
    }

    /// @notice Signal commitment to task
    /// @param commitment_ Commitment hash
    /** @dev
        this is used so others cannot steal solution with copying task from
        mempool and publishing in advance
        commitment is keccak256(abi.encode(validator, taskid_, cid_))
        any account may register a commitment on behalf of a validator */
    function signalCommitment(bytes32 commitment_) external notPaused {
        require(commitments[commitment_] == 0, "commitment exists"); // do not allow commitment time to be reset
        commitments[commitment_] = getBlockNumberNow();
        emit SignalCommitment(msg.sender, commitment_);
    }

    /// @notice Submit a solution
    /// @dev this implements the core logic for submitting a solution. make sure to call _submitSolutionCommon before this
    /// @param taskid_ Task hash
    /// @param cid_ IPFS cid of solution
    function _submitSolution(
        bytes32 taskid_,
        bytes calldata cid_
    ) internal {
        require(tasks[taskid_].model != bytes32(0x0), "task does not exist");
        require(
            solutions[taskid_].validator == address(0x0),
            "solution already submitted"
        );

        bytes32 commitment = generateCommitment(msg.sender, taskid_, cid_);
        require(commitments[commitment] > 0, "non existent commitment");
        // commitment must be in past while rewards are active
        require(
            commitments[commitment] < getBlockNumberNow(),
            "commitment must be in past"
        );

        solutions[taskid_] = Solution({
            validator: msg.sender,
            blocktime: uint64(block.timestamp),
            cid: cid_,
            claimed: false
        });

        solutionsStake[taskid_] = solutionsStakeAmount;

        emit SolutionSubmitted(msg.sender, taskid_);
    }

    /// @notice Perform common actions&checks for submitting a solution
    /// @dev this is used by both submitSolution and bulkSubmitSolution
    /// @param n_ Number of solutions to submit
    function _submitSolutionCommon(uint256 n_) internal {
        // v2 (solutions must have been submitted after last successful contestation));
        require(
            block.timestamp >
                lastContestationLossTime[msg.sender] +
                    minClaimSolutionTime +
                    minContestationVotePeriodTime,
            "submitSolution cooldown after lost contestation"
        );

        // v2
        validators[msg.sender].staked -= solutionsStakeAmount * n_;

        // v3
        // pat: strict greater than comparison to rate limit solution submissions
        // in sequential blocks having the same timestamp
        require(
            block.timestamp - lastSolutionSubmission[msg.sender] >
                solutionRateLimit * n_ / 1e18,
            "solution rate limit"
        );
        lastSolutionSubmission[msg.sender] = block.timestamp;
        // end v3

        // move onlyValidator check here to avoid duplicate work for bulkSubmitSolution
        require(_onlyValidator(msg.sender), "min staked too low");
    }


    /// @notice Submit a solution
    /// @dev this is not onlyValidator as that is checked in _submitSolution
    /// @param taskid_ Task hash
    /// @param cid_ IPFS cid of solution
    function submitSolution(
        bytes32 taskid_,
        bytes calldata cid_
    ) external notPaused {
        _submitSolutionCommon(1);
        _submitSolution(taskid_, cid_);
    }

    /// @notice Bulk submit solutions
    /// @dev Added in v3
    /// @param taskids_ Task hashes
    /// @param cids_ IPFS cids of solutions
    function bulkSubmitSolution(
        bytes32[] calldata taskids_,
        bytes[] calldata cids_
    ) external notPaused {
        // tasks will fail if they do not exist / cids are not valid
        // require(taskids_.length == cids_.length, "length mismatch");

        _submitSolutionCommon(taskids_.length);

        for (uint256 i = 0; i < taskids_.length; ++i) {
            _submitSolution(taskids_[i], cids_[i]);
        }
    }

    /// @notice Claim solution fee and reward (if available)
    /** @dev this is separated out as it is used both in:
     * normal claimSolution
     * and contestationVoteFinish (for failed contestations)
     */
    function _claimSolutionFeesAndReward(bytes32 taskid_) internal {
        uint256 modelFee = models[tasks[taskid_].model].fee;

        // This is necessary in case model changes fee to prevent drain
        // note: currently it is not possible for a model to change fee
        if (modelFee > tasks[taskid_].fee) {
            modelFee = 0;
        }
        if (modelFee > 0) {
            baseToken.transfer(models[tasks[taskid_].model].addr, modelFee);
        }

        uint256 remainingFee = tasks[taskid_].fee - modelFee;

        uint256 treasuryFee = remainingFee -
            ((remainingFee * (1e18 - solutionFeePercentage)) / 1e18);
        accruedFees += treasuryFee;

        // avoid 0 value transfer and emitted event
        uint256 validatorFee = remainingFee - treasuryFee;
        if (validatorFee > 0) {
            baseToken.transfer(
                solutions[taskid_].validator,
                remainingFee - treasuryFee
            );
        }

        uint256 modelRate = models[tasks[taskid_].model].rate;
        if (modelRate > 0) {
            uint256 total = (getReward() * modelRate) / 1e18;

            if (total > 0) {
                uint256 treasuryReward = total -
                    (total * (1e18 - treasuryRewardPercentage)) /
                    1e18;

                // v3
                uint256 taskOwnerReward = total -
                    (total * (1e18 - taskOwnerRewardPercentage)) /
                    1e18;

                baseToken.transfer(
                    solutions[taskid_].validator,
                    total - treasuryReward - taskOwnerReward // v3
                );
                baseToken.transfer(treasury, treasuryReward);
                baseToken.transfer(tasks[taskid_].owner, taskOwnerReward); // v3
            }
        }

        // return solution staked amount to validator
        validators[solutions[taskid_].validator].staked += solutionsStake[
            taskid_
        ]; // v2

        // we do not include treasuryFee in totalHeld reduction as not transferred here
        totalHeld -= tasks[taskid_].fee - treasuryFee; // v3
    }

    /// @notice Claim solution
    /// @dev anyone can claim, reward goes to solution validator not claimer
    /// @param taskid_ Task hash
    function claimSolution(bytes32 taskid_) external notPaused {
        // v2 (check if staked amount of validator is enough to claim)
        require(
            validators[solutions[taskid_].validator].staked -
                validatorWithdrawPendingAmount[solutions[taskid_].validator] >=
                getValidatorMinimum(),
            "validator min staked too low"
        );
        require(
            solutions[taskid_].validator != address(0x0),
            "solution not found"
        );
        // if there is a failed contestation the claiming must be done from contestationVoteFinish
        require(
            contestations[taskid_].validator == address(0x0),
            "has contestation"
        );
        require(
            solutions[taskid_].blocktime <
                block.timestamp - minClaimSolutionTime,
            "not enough delay"
        );
        // v2 (solutions must have been submitted after last successful contestation)
        require(
            solutions[taskid_].blocktime >
                lastContestationLossTime[solutions[taskid_].validator] +
                    minClaimSolutionTime +
                    minContestationVotePeriodTime,
            "claimSolution cooldown after lost contestation"
        );

        require(solutions[taskid_].claimed == false, "already claimed");

        solutions[taskid_].claimed = true;

        // put here so that this is first event
        emit SolutionClaimed(solutions[taskid_].validator, taskid_);

        _claimSolutionFeesAndReward(taskid_);
    }

    /// @notice Contest a submitted solution
    /// @param taskid_ Task hash
    function submitContestation(
        bytes32 taskid_
    ) external notPaused onlyValidator {
        require(
            solutions[taskid_].validator != address(0x0),
            "solution does not exist"
        );
        require(
            contestations[taskid_].validator == address(0x0),
            "contestation already exists"
        );
        require(
            block.timestamp <
                solutions[taskid_].blocktime + minClaimSolutionTime,
            "too late"
        );
        require(!solutions[taskid_].claimed, "wtf");

        uint256 slashAmount = getSlashAmount();

        contestations[taskid_] = Contestation({
            validator: msg.sender,
            blocktime: uint64(block.timestamp),
            finish_start_index: 0,
            slashAmount: slashAmount
        });

        emit ContestationSubmitted(msg.sender, taskid_);

        _voteOnContestation(taskid_, true, msg.sender); // contestor obviously agrees

        // if the solution submitter doesnt have enough staked remaining the vote is not needed
        // there will be no rewards for the contestor
        // however, we allow this to happen so the user may reclaim their fee paid

        // we do not care about validatorWithdrawPendingAmount as it shouldnt matter if they
        // submit invalid tasks then attempt to withdraw. the amount they have staked is max
        // they can withdraw.
        if (validators[solutions[taskid_].validator].staked >= slashAmount) {
            // the accused validator automatically votes against
            _voteOnContestation(taskid_, false, solutions[taskid_].validator);
        }
    }

    /// @notice Check if contestation voting period ended
    /// @dev This can be used to determine if contestation can be finished
    /// @param taskid_ Task hash
    /// @return Whether contestation voting period ended
    function votingPeriodEnded(bytes32 taskid_) public view returns (bool) {
        return block.timestamp >
            contestations[taskid_].blocktime +
            minContestationVotePeriodTime +
            // v3
            ((contestationVoteYeas[taskid_].length + contestationVoteNays[taskid_].length) * contestationVoteExtensionTime);
    }

    /// @notice Check if validator can vote on a contestation
    /// @dev Determines if validator may vote on a contestation
    /// @param addr_ Address of validator
    /// @param taskid_ Task hash
    /// @return Whether validator can vote on contestation (0) or error code
    function validatorCanVote(
        address addr_,
        bytes32 taskid_
    ) public view returns (uint256) {
        // contestation doesn't exist
        if (contestations[taskid_].validator == address(0x0)) {
            return 0x01;
        }

        // voting period ended
        if (votingPeriodEnded(taskid_)) {
            return 0x02;
        }

        // already voted
        if (contestationVoted[taskid_][addr_]) {
            return 0x03;
        }

        // if not staked ever, cannot vote
        // this ensures validator has staked
        if (validators[addr_].since == 0) {
            return 0x04;
        }

        // check in case something goes really wrong
        if (validators[addr_].since < maxContestationValidatorStakeSince) {
            return 0x05;
        }

        // if staked after contestation+period, cannot vote
        if (
            validators[addr_].since - maxContestationValidatorStakeSince >
            contestations[taskid_].blocktime
        ) {
            return 0x06;
        }

        // otherwise, validator can vote!
        return 0x00;
    }

    /// @notice Vote on a contestation (internal)
    /// @dev This exists to enable autovote on contestation submission
    /// @param taskid_ Task hash
    /// @param yea_ Yea or nay
    /// @param addr_ Address of voter
    function _voteOnContestation(
        bytes32 taskid_,
        bool yea_,
        address addr_
    ) internal {
        contestationVoted[taskid_][addr_] = true;
        if (yea_) {
            contestationVoteYeas[taskid_].push(addr_);
        } else {
            contestationVoteNays[taskid_].push(addr_);
        }

        // we reduce staked amount here, this is refunded if contestation is won
        // if we did not reduce slashAmount now, someone could contest every task
        // before the timer ran out for just losing validatorDeposit eventually
        validators[addr_].staked -= contestations[taskid_].slashAmount;

        emit ContestationVote(addr_, taskid_, yea_);
    }

    /// @notice Vote on a contestation
    /// @param taskid_ Task hash
    /// @param yea_ Yea or nay
    function voteOnContestation(
        bytes32 taskid_,
        bool yea_
    ) external notPaused onlyValidator {
        require(validatorCanVote(msg.sender, taskid_) == 0x0, "not allowed");
        _voteOnContestation(taskid_, yea_, msg.sender);
    }

    /// @notice Finish contestation voting period
    /// @param taskid_ Task hash
    /// @param amnt_ Amount of votes to process
    function contestationVoteFinish(
        bytes32 taskid_,
        uint32 amnt_
    ) external notPaused {
        require(
            contestations[taskid_].validator != address(0x0),
            "contestation doesn't exist"
        );
        require(votingPeriodEnded(taskid_), "voting period not ended");
        // we need at least 1 iteration for special handling of 0 index
        require(amnt_ > 0, "amnt too small");

        uint32 yeaAmount = uint32(contestationVoteYeas[taskid_].length);
        uint32 nayAmount = uint32(contestationVoteNays[taskid_].length);

        uint32 start_idx = contestations[taskid_].finish_start_index;
        uint32 end_idx = contestations[taskid_].finish_start_index + amnt_;
        uint256 slashAmount = contestations[taskid_].slashAmount;

        // if equal in amount, we side with nays
        // this is for contestation succeeding
        if (yeaAmount > nayAmount) {
            uint256 totalVal = nayAmount * slashAmount;
            uint256 valToOriginator = yeaAmount == 1
                ? totalVal
                : totalVal - (totalVal / 2);
            uint256 valToOtherYeas = yeaAmount == 1
                ? 0
                : (totalVal - valToOriginator) / (yeaAmount - 1);

            for (uint256 i = start_idx; i < end_idx; i++) {
                if (i < yeaAmount) {
                    address a = contestationVoteYeas[taskid_][i];
                    validators[a].staked += slashAmount; // refund
                    if (i == 0) {
                        baseToken.transfer(a, valToOriginator);
                        totalHeld -= valToOriginator; // v3
                    } else {
                        baseToken.transfer(a, valToOtherYeas);
                        totalHeld -= valToOtherYeas; // v3
                    }
                }
            }

            if (contestations[taskid_].finish_start_index == 0) {
                // refund fees paid back to user
                baseToken.transfer(tasks[taskid_].owner, tasks[taskid_].fee);
                totalHeld -= tasks[taskid_].fee; // v3

                // give solution staked amount to originator of contestation
                validators[contestationVoteYeas[taskid_][0]]
                    .staked += solutionsStake[taskid_]; // v2

                lastContestationLossTime[solutions[taskid_].validator] = block
                    .timestamp;
            }
        } else {
            // this is for contestation failing
            uint256 totalVal = yeaAmount * slashAmount;
            uint256 valToAccused = nayAmount == 1 ? totalVal : totalVal / 2;
            uint256 valToOtherNays = nayAmount == 1
                ? 0
                : (totalVal - valToAccused) / (nayAmount - 1);

            for (uint256 i = start_idx; i < end_idx; i++) {
                if (i < nayAmount) {
                    address a = contestationVoteNays[taskid_][i];
                    validators[a].staked += slashAmount; // refund
                    if (i == 0) {
                        baseToken.transfer(a, valToAccused);
                        totalHeld -= valToAccused; // v3
                    } else {
                        baseToken.transfer(a, valToOtherNays);
                        totalHeld -= valToOtherNays; // v3
                    }
                }
            }

            if (contestations[taskid_].finish_start_index == 0) {
                // solver to claim solution like normal
                _claimSolutionFeesAndReward(taskid_);
            }
        }

        contestations[taskid_].finish_start_index = end_idx;

        emit ContestationVoteFinish(taskid_, start_idx, end_idx);
    }
}
