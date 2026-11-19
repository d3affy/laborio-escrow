// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEscrow} from "./interfaces/IEscrow.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Errors} from "./libs/Errors.sol";

/// @notice Factory for EIP-1167 clones of Escrow implementation (supports both legacy and milestone modes)
contract EscrowFactory {
    address public immutable impl;
    address public feeCollector;
    uint16 public feeBps;
    address public immutable owner;
    address public arbitrator;
    bool public paused; // pause create()
    bool public fundPaused; // pause Escrow.fund() globally
    uint96 public defaultMinPartialAmount;
    mapping(address => bool) private _allowedToken;

    struct EscrowRef {
        address proxy;
        address client;
        address freelancer;
        uint16 milestoneCount; // 0 = legacy mode, >0 = milestone mode
    }
    EscrowRef[] public escrows;

    event EscrowCreated(
        uint256 indexed id,
        address indexed proxy,
        address client,
        address freelancer,
        address token,
        uint256 amount,
        uint16 milestoneCount
    );
    event TokenAllowed(address indexed token, bool allowed);
    event PausedSet(bool paused);
    event FundPausedSet(bool paused);
    event ArbitratorSet(address indexed arbitrator);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "!owner");
    }

    constructor(address _impl, address _feeCollector, uint16 _feeBps, uint96 _defaultMinPartialAmount) {
        if (_impl.code.length == 0 || _feeCollector == address(0)) revert Errors.ZeroAddress();
        if (_feeBps > 500) revert Errors.AmountMismatch();
        owner = msg.sender;
        arbitrator = msg.sender;
        impl = _impl;
        feeCollector = _feeCollector;
        feeBps = _feeBps;
        defaultMinPartialAmount = _defaultMinPartialAmount;
    }

    /// @notice Create legacy escrow (backward compatible)
    function create(address client, address freelancer, address token, uint256 amount, uint64 deadline)
        external
        returns (uint256 id, address proxy)
    {
        if (paused) revert Errors.Paused();
        if (!_allowedToken[token]) revert Errors.TokenNotAllowed();

        proxy = Clones.clone(impl);
        IEscrow(proxy).init(client, freelancer, token, amount, deadline, feeBps, feeCollector);
        escrows.push(EscrowRef({proxy: proxy, client: client, freelancer: freelancer, milestoneCount: 0}));
        id = escrows.length - 1;
        emit EscrowCreated(id, proxy, client, freelancer, token, amount, 0);
    }

    /// @notice Create escrow with milestones
    function createWithMilestones(
        address client,
        address freelancer,
        address token,
        uint128[] calldata budgets,
        uint64[] calldata deadlines,
        uint32[] calldata reviewWindows,
        bytes32[] calldata metaHashes,
        IEscrow.FundingMode fundingMode
    ) external returns (uint256 id, address proxy) {
        if (paused) revert Errors.Paused();
        if (!_allowedToken[token]) revert Errors.TokenNotAllowed();

        proxy = Clones.clone(impl);
        IEscrow(proxy)
            .initWithMilestones(
                client,
                freelancer,
                token,
                budgets,
                deadlines,
                reviewWindows,
                metaHashes,
                feeBps,
                feeCollector,
                fundingMode,
                defaultMinPartialAmount
            );

        // Calculate total amount
        uint128 total = 0;
        for (uint256 i = 0; i < budgets.length; i++) {
            total += budgets[i];
        }

        escrows.push(
            EscrowRef({proxy: proxy, client: client, freelancer: freelancer, milestoneCount: uint16(budgets.length)})
        );
        id = escrows.length - 1;
        emit EscrowCreated(id, proxy, client, freelancer, token, total, uint16(budgets.length));
    }

    function setFee(uint16 bps) external onlyOwner {
        if (bps > 500) revert Errors.AmountMismatch();
        feeBps = bps;
    }

    function setFeeCollector(address c) external onlyOwner {
        if (c == address(0)) revert Errors.ZeroAddress();
        feeCollector = c;
    }

    function setDefaultMinPartialAmount(uint96 amount) external onlyOwner {
        defaultMinPartialAmount = amount;
    }

    function setArbitrator(address nextArbitrator) external onlyOwner {
        if (nextArbitrator == address(0)) revert Errors.ZeroAddress();
        arbitrator = nextArbitrator;
        emit ArbitratorSet(nextArbitrator);
    }

    function nextEscrowId() external view returns (uint256) {
        return escrows.length;
    }

    // --- Controls ---
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setFundPaused(bool p) external onlyOwner {
        fundPaused = p;
        emit FundPausedSet(p);
    }

    // --- Allowlist ---
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        _allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function isTokenAllowed(address token) external view returns (bool) {
        return _allowedToken[token];
    }
}
