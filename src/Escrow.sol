// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {Errors} from "./libs/Errors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFactoryConfig} from "./interfaces/IFactoryConfig.sol";

/// @notice Unified ERC20-based escrow with optional milestone support
/// @dev Security: reentrancy guarded, SafeERC20, explicit state checks, bounded loops
/// @dev Supports both legacy single-payment and milestone-based workflows
contract Escrow is IEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint16 private constant MAX_MILESTONES = 32;
    uint16 private constant MAX_PARTIALS_PER_MILESTONE = 10;
    uint16 private constant MAX_FEE_BPS = 500; // 5%

    // Amounts use the settlement token's native units.
    struct Milestone {
        uint128 budget;
        uint128 deposited;
        uint128 released;
        uint128 refunded;
        uint64 deadline;
        uint32 reviewWindow;
        MilestoneState state;
        bytes32 evidenceHash;
        bytes32 metaHash;
        uint64 submissionTs;
        uint16 partialCount;
    }

    // Core state
    address public factory;
    address public client;
    address public freelancer;
    address public token;
    uint256 public escrowId;
    uint16 public feeBps;
    address public feeCollector;
    bool private _initialized;

    // Legacy mode fields (used when milestoneCount == 0)
    State public state; // Legacy state
    uint256 public amount; // Legacy total amount
    uint64 public deadline; // Legacy deadline

    // Milestone mode fields (used when milestoneCount > 0)
    EscrowState public escrowState;
    uint8 public decimals;
    uint128 public totalAmount; // sum of all milestone budgets
    uint128 public funded;
    uint128 public releasedTotal;
    uint128 public refundedTotal;
    uint16 public milestoneCount;
    uint96 public minPartialAmount;
    FundingMode public fundingMode;
    Milestone[] private milestones;

    modifier onlyClient() {
        _onlyClient();
        _;
    }

    function _onlyClient() internal view {
        if (msg.sender != client) revert Errors.NotClient();
    }

    modifier onlyArbitrator() {
        _onlyArbitrator();
        _;
    }

    function _onlyArbitrator() internal view {
        if (msg.sender != IFactoryConfig(factory).arbitrator()) revert Errors.NotArbitrator();
    }

    constructor() {
        _initialized = true; // Only factory-created clones accept initialization.
    }

    /// @notice Legacy init (backward compatible, single milestone)
    function init(
        address _client,
        address _freelancer,
        address _token,
        uint256 _amount,
        uint64 _deadline,
        uint16 _feeBps,
        address _feeCollector
    ) external {
        if (_initialized) revert Errors.WrongState();
        if (_client == address(0) || _freelancer == address(0) || _token == address(0) || _feeCollector == address(0)) {
            revert Errors.ZeroAddress();
        }

        factory = msg.sender;
        escrowId = IFactoryConfig(msg.sender).nextEscrowId();
        _initialized = true;

        client = _client;
        freelancer = _freelancer;
        token = _token;
        if (_amount == 0 || _feeBps > MAX_FEE_BPS) revert Errors.AmountMismatch();
        amount = _amount;
        deadline = _deadline;
        feeBps = _feeBps;
        feeCollector = _feeCollector;
        state = State.Created;
        milestoneCount = 0; // Mark as legacy mode
    }

    /// @notice Initialize with milestones
    function initWithMilestones(
        address _client,
        address _freelancer,
        address _token,
        uint128[] calldata _budgets,
        uint64[] calldata _deadlines,
        uint32[] calldata _reviewWindows,
        bytes32[] calldata _metaHashes,
        uint16 _feeBps,
        address _feeCollector,
        FundingMode _fundingMode,
        uint96 _minPartialAmount
    ) external {
        if (_initialized) revert Errors.WrongState();
        if (_client == address(0) || _freelancer == address(0) || _token == address(0) || _feeCollector == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (_budgets.length == 0 || _budgets.length > MAX_MILESTONES) revert Errors.InvalidMilestoneCount();
        if (
            _budgets.length != _deadlines.length || _budgets.length != _reviewWindows.length
                || _budgets.length != _metaHashes.length
        ) {
            revert Errors.BudgetMismatch();
        }
        if (_feeBps > MAX_FEE_BPS) revert Errors.AmountMismatch();

        factory = msg.sender;
        escrowId = IFactoryConfig(msg.sender).nextEscrowId();
        _initialized = true;
        client = _client;
        freelancer = _freelancer;
        token = _token;
        feeBps = _feeBps;
        feeCollector = _feeCollector;
        fundingMode = _fundingMode;
        minPartialAmount = _minPartialAmount;

        // Cache decimals (fallback to 6 if call fails)
        try IERC20Metadata(_token).decimals() returns (uint8 dec) {
            if (dec > 18) revert Errors.AmountMismatch(); // Unsupported
            decimals = dec;
        } catch {
            decimals = 6;
        }

        // Validate and store milestones
        uint128 sum = 0;
        for (uint16 i = 0; i < _budgets.length; i++) {
            if (_budgets[i] == 0) revert Errors.BudgetMismatch();
            sum += _budgets[i];
            milestones.push(
                Milestone({
                    budget: _budgets[i],
                    deposited: 0,
                    released: 0,
                    refunded: 0,
                    deadline: _deadlines[i],
                    reviewWindow: _reviewWindows[i],
                    state: MilestoneState.Planned,
                    evidenceHash: bytes32(0),
                    metaHash: _metaHashes[i],
                    submissionTs: 0,
                    partialCount: 0
                })
            );
            emit MilestoneAdded(escrowId, i, _budgets[i], _deadlines[i], _reviewWindows[i], _metaHashes[i]);
        }
        totalAmount = sum;
        milestoneCount = uint16(_budgets.length);
        escrowState = EscrowState.Created;
    }

    // ========== LEGACY MODE FUNCTIONS (backward compatible) ==========

    /// @notice Legacy fund (single milestone)
    function fund() external nonReentrant onlyClient {
        if (milestoneCount > 0) revert Errors.WrongState(); // Must use milestone functions
        if (state != State.Created) revert Errors.WrongState();
        if (IFactoryConfig(factory).fundPaused()) revert Errors.Paused();
        _receiveExact(amount);
        state = State.Funded;
        emit Funded(escrowId, amount);
    }

    /// @notice Legacy release (single milestone)
    function release(address to, uint256 amt) external nonReentrant onlyClient {
        if (milestoneCount > 0) revert Errors.WrongState(); // Must use milestone functions
        if (state != State.Funded && state != State.InReview) revert Errors.WrongState();
        if (amt != amount) revert Errors.AmountMismatch();
        uint256 fee = Math.mulDiv(amt, feeBps, 10_000);
        uint256 net = amt - fee;
        state = State.Released;
        IERC20(token).safeTransfer(feeCollector, fee);
        IERC20(token).safeTransfer(to, net);
        emit Released(escrowId, to, amt, fee);
    }

    /// @notice Legacy refund (single milestone)
    function refund() external nonReentrant onlyClient {
        if (milestoneCount > 0) revert Errors.WrongState(); // Must use milestone functions
        if (state != State.Funded && state != State.InReview) revert Errors.WrongState();
        state = State.Refunded;
        IERC20(token).safeTransfer(client, amount);
        emit Refunded(escrowId, amount);
    }

    // ========== MILESTONE MODE FUNCTIONS ==========

    /// @notice Deposit toward the agreed total in full-upfront mode.
    function fundMilestones(uint128 value) external nonReentrant onlyClient {
        _fundUpfront(value);
    }

    /// @notice Complete an outstanding upfront deposit in one or more instalments.
    function topUp(uint128 value) external nonReentrant onlyClient {
        _fundUpfront(value);
        emit TopUp(escrowId, value);
    }

    function _fundUpfront(uint128 value) internal {
        if (milestoneCount == 0 || fundingMode != FundingMode.FullUpfront || escrowState != EscrowState.Created) {
            revert Errors.WrongState();
        }
        if (value == 0 || value > totalAmount - funded) revert Errors.AmountMismatch();
        _deposit(value);
        if (funded == totalAmount) escrowState = EscrowState.Funded;
    }

    /// @notice Deposit toward one milestone. Other milestones cannot spend this allocation.
    function fundMilestone(uint16 msId, uint128 value) external nonReentrant onlyClient {
        if (fundingMode != FundingMode.PerMilestone) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        if (ms.state != MilestoneState.Planned) revert Errors.WrongState();
        if (value == 0 || value > ms.budget - ms.deposited) revert Errors.AmountMismatch();
        ms.deposited += value;
        _deposit(value);
        if (escrowState == EscrowState.Created) escrowState = EscrowState.Funded;
    }

    function _deposit(uint128 value) internal {
        if (IFactoryConfig(factory).fundPaused()) revert Errors.Paused();
        _receiveExact(value);
        funded += value;
        emit Funded(escrowId, value);
    }

    function _receiveExact(uint256 value) internal {
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(client, address(this), value);
        if (asset.balanceOf(address(this)) - beforeBalance != value) revert Errors.AmountMismatch();
    }

    /// @notice Return an incomplete deposit before it commits a milestone to work.
    /// @dev In upfront mode the shared deposit is identified by index zero.
    function withdrawIncompleteFunding(uint16 msId) external nonReentrant onlyClient {
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        uint128 value;
        if (fundingMode == FundingMode.FullUpfront) {
            if (msId != 0 || escrowState != EscrowState.Created) revert Errors.WrongState();
            value = funded;
        } else {
            Milestone storage ms = milestones[msId];
            if (ms.state != MilestoneState.Planned || ms.deposited == ms.budget) revert Errors.WrongState();
            value = ms.deposited;
            ms.deposited = 0;
        }
        if (value == 0) revert Errors.InsufficientFunding();
        funded -= value;
        IERC20(token).safeTransfer(client, value);
        emit FundingWithdrawn(escrowId, msId, value);
    }

    /// @notice Submit work for a milestone
    function submitWork(uint16 msId, bytes32 evidenceHash) external nonReentrant {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        if (msg.sender != freelancer) revert Errors.NotClient();

        Milestone storage ms = milestones[msId];

        if (ms.state != MilestoneState.Planned) {
            if (ms.state != MilestoneState.InReview && ms.state != MilestoneState.PartiallyReleased) {
                revert Errors.WrongState();
            }
            uint128 rem = ms.budget - ms.released - ms.refunded;
            if (rem == 0) revert Errors.WrongState();
            if (ms.submissionTs + ms.reviewWindow > block.timestamp) revert Errors.AlreadySubmitted();
        }

        if (fundingMode == FundingMode.FullUpfront) {
            if (funded < totalAmount) revert Errors.InsufficientFunding();
        } else {
            if (ms.deposited < ms.budget) revert Errors.InsufficientFunding();
        }

        ms.state = MilestoneState.InReview;
        ms.evidenceHash = evidenceHash;
        ms.submissionTs = uint64(block.timestamp);
        emit MilestoneSubmitted(escrowId, msId, evidenceHash);
    }

    /// @notice Release full remaining budget of a milestone
    function releaseMilestone(uint16 msId) external nonReentrant onlyClient {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        if (ms.state != MilestoneState.InReview && ms.state != MilestoneState.PartiallyReleased) {
            revert Errors.NotInReview();
        }

        uint128 rem = ms.budget - ms.released - ms.refunded;
        if (rem == 0) revert Errors.ExceedsRemaining();

        _releaseInternal(msId, rem);
    }

    /// @notice Release partial amount from a milestone
    function releasePartial(uint16 msId, uint128 _amount) external nonReentrant onlyClient {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        if (ms.state != MilestoneState.InReview && ms.state != MilestoneState.PartiallyReleased) {
            revert Errors.NotInReview();
        }

        uint128 rem = ms.budget - ms.released - ms.refunded;
        if (_amount == 0 || _amount > rem) revert Errors.ExceedsRemaining();
        if (_amount < minPartialAmount) revert Errors.AmountTooSmall();
        if (ms.partialCount >= MAX_PARTIALS_PER_MILESTONE) revert Errors.TooManyPartials();

        ms.partialCount++;
        _releaseInternal(msId, _amount);
    }

    function _releaseInternal(uint16 msId, uint128 _amount) internal {
        Milestone storage ms = milestones[msId];

        uint128 fee = uint128((uint256(_amount) * feeBps) / 10_000);
        uint128 net = _amount - fee;

        ms.released += _amount;
        releasedTotal += _amount;

        uint128 rem = ms.budget - ms.released - ms.refunded;
        if (rem == 0) {
            ms.state = MilestoneState.Released;
        } else {
            ms.state = MilestoneState.PartiallyReleased;
        }

        IERC20(token).safeTransfer(feeCollector, fee);
        IERC20(token).safeTransfer(freelancer, net);

        emit MilestoneReleased(escrowId, msId, _amount, ms.released, rem, fee);

        _checkClosed();
    }

    /// @notice Refund remaining budget of a milestone to client
    function refundMilestone(uint16 msId) external nonReentrant onlyClient {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        if (ms.state == MilestoneState.Planned) {
            if (fundingMode == FundingMode.FullUpfront ? funded < totalAmount : ms.deposited < ms.budget) {
                revert Errors.InsufficientFunding();
            }
        } else if (ms.state != MilestoneState.InReview && ms.state != MilestoneState.PartiallyReleased) {
            revert Errors.NotInReview();
        }

        uint128 rem = ms.budget - ms.released - ms.refunded;
        if (rem == 0) revert Errors.ExceedsRemaining();

        ms.refunded += rem;
        refundedTotal += rem;
        ms.state = MilestoneState.Refunded;

        IERC20(token).safeTransfer(client, rem);

        emit MilestoneRefunded(escrowId, msId, rem, ms.refunded, 0);

        _checkClosed();
    }

    /// @notice Dispute a milestone
    function disputeMilestone(uint16 msId, bytes32 reasonHash) external nonReentrant {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        if (msg.sender != client && msg.sender != freelancer) revert Errors.NotClient();
        Milestone storage ms = milestones[msId];
        if (ms.state != MilestoneState.InReview && ms.state != MilestoneState.PartiallyReleased) {
            revert Errors.WrongState();
        }

        ms.state = MilestoneState.Disputed;
        if (escrowState != EscrowState.Disputed) {
            escrowState = EscrowState.Disputed;
        }

        emit MilestoneDisputed(escrowId, msId, reasonHash);
    }

    /// @notice Resolve a disputed milestone (arbitrator only)
    function resolveMilestone(uint16 msId, address to, uint128 _amount) external nonReentrant onlyArbitrator {
        if (milestoneCount == 0) revert Errors.WrongState();
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        if (ms.state != MilestoneState.Disputed) revert Errors.WrongState();

        uint128 rem = ms.budget - ms.released - ms.refunded;
        if (_amount > rem) revert Errors.ExceedsRemaining();

        if (_amount > 0) {
            uint128 fee = uint128((uint256(_amount) * feeBps) / 10_000);
            uint128 net = _amount - fee;

            ms.released += _amount;
            releasedTotal += _amount;

            IERC20(token).safeTransfer(feeCollector, fee);
            IERC20(token).safeTransfer(to, net);
        }

        uint128 refundAmount = rem - _amount;
        if (refundAmount > 0) {
            ms.refunded += refundAmount;
            refundedTotal += refundAmount;
            IERC20(token).safeTransfer(client, refundAmount);
            emit MilestoneRefunded(escrowId, msId, refundAmount, ms.refunded, 0);
        }
        ms.state = MilestoneState.Resolved;
        emit MilestoneResolved(escrowId, msId, to, _amount);

        bool anyDisputed = false;
        for (uint16 i = 0; i < milestoneCount; i++) {
            if (milestones[i].state == MilestoneState.Disputed) {
                anyDisputed = true;
                break;
            }
        }
        if (!anyDisputed && escrowState == EscrowState.Disputed) {
            escrowState = EscrowState.Resolved;
        }

        _checkClosed();
    }

    function _checkClosed() internal {
        if (escrowState == EscrowState.Closed) return;

        for (uint16 i = 0; i < milestoneCount; i++) {
            Milestone storage ms = milestones[i];
            uint128 rem = ms.budget - ms.released - ms.refunded;
            if (rem > 0) return;
        }

        escrowState = EscrowState.Closed;
        emit Closed(escrowId);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get milestone details
    function getMilestone(uint16 msId) external view returns (MilestoneView memory) {
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        uint128 rem = ms.budget - ms.released - ms.refunded;
        return MilestoneView({
            budget: ms.budget,
            released: ms.released,
            refunded: ms.refunded,
            deadline: ms.deadline,
            reviewWindow: ms.reviewWindow,
            state: ms.state,
            evidenceHash: ms.evidenceHash,
            metaHash: ms.metaHash,
            remaining: rem,
            partialCount: ms.partialCount
        });
    }

    /// @notice Get remaining budget of a milestone
    function remaining(uint16 msId) external view returns (uint128) {
        if (msId >= milestoneCount) revert Errors.InvalidMilestoneId();
        Milestone storage ms = milestones[msId];
        return ms.budget - ms.released - ms.refunded;
    }

    /// @notice Get escrow token balance
    function escrowBalance() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Check if escrow is closed
    function isClosed() external view returns (bool) {
        if (milestoneCount == 0) {
            return state == State.Released || state == State.Refunded;
        }
        return escrowState == EscrowState.Closed;
    }
}
