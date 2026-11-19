// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEscrow {
    // Legacy single-milestone states
    enum State {
        Created,
        Funded,
        InReview,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    // Milestone-specific enums
    enum EscrowState {
        Created,
        Funded,
        Disputed,
        Resolved,
        Closed
    }
    enum MilestoneState {
        Planned,
        InReview,
        PartiallyReleased,
        Released,
        Refunded,
        Disputed,
        Resolved
    }
    enum FundingMode {
        FullUpfront,
        PerMilestone
    }

    struct MilestoneView {
        uint128 budget;
        uint128 released;
        uint128 refunded;
        uint64 deadline;
        uint32 reviewWindow;
        MilestoneState state;
        bytes32 evidenceHash;
        bytes32 metaHash;
        uint128 remaining;
        uint16 partialCount;
    }

    // Legacy events (single-milestone)
    event EscrowCreated(uint256 id, address client, address freelancer, address token, uint256 amount, uint64 deadline);
    event Funded(uint256 id, uint256 amount);
    event Released(uint256 id, address to, uint256 amount, uint256 fee);
    event Refunded(uint256 id, uint256 amount);
    event Disputed(uint256 id, bytes32 reason);
    event Resolved(uint256 id, address to, uint256 amount);

    // Milestone events
    event MilestoneAdded(
        uint256 indexed escrowId, uint16 msId, uint128 budget, uint64 deadline, uint32 reviewWindow, bytes32 metaHash
    );
    event MilestoneSubmitted(uint256 indexed escrowId, uint16 msId, bytes32 evidenceHash);
    event MilestoneReleased(
        uint256 indexed escrowId,
        uint16 msId,
        uint128 amount,
        uint128 releasedCumulative,
        uint128 remaining,
        uint256 fee
    );
    event MilestoneRefunded(
        uint256 indexed escrowId, uint16 msId, uint128 amount, uint128 refundedCumulative, uint128 remaining
    );
    event MilestoneDisputed(uint256 indexed escrowId, uint16 msId, bytes32 reasonHash);
    event MilestoneResolved(uint256 indexed escrowId, uint16 msId, address to, uint128 amount);
    event FundingWithdrawn(uint256 indexed escrowId, uint16 msId, uint128 amount);
    event TopUp(uint256 indexed escrowId, uint128 amount);
    event Closed(uint256 indexed escrowId);

    // Factory-only initializers
    // Legacy init (single milestone, backward compatible)
    function init(
        address _client,
        address _freelancer,
        address _token,
        uint256 _amount,
        uint64 _deadline,
        uint16 _feeBps,
        address _feeCollector
    ) external;

    // Milestone init
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
    ) external;
}
