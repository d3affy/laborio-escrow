// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EscrowTest is Test {
    MockUSDC usdc;
    EscrowFactory factory;
    Escrow impl;
    address client = address(0xC1);
    address free = address(0xF1);
    address arbitrator = address(0xA1);
    address feeCollector = address(0xFEe);

    function setUp() public {
        usdc = new MockUSDC();
        impl = new Escrow();
        factory = new EscrowFactory(address(impl), feeCollector, 100, 1e6); // 1% fee, 1 USDC min partial
        // allow USDC by default
        factory.setTokenAllowed(address(usdc), true);
    }

    function test_flow_release() public {
        // Create escrow
        (uint256 id, address proxy) =
            factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));
        assertEq(id, 0);

        // Check initial state
        Escrow escrow = Escrow(proxy);
        assertEq(escrow.client(), client);
        assertEq(escrow.freelancer(), free);
        assertEq(uint256(escrow.state()), uint256(IEscrow.State.Created));

        // Fund escrow
        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fund();
        vm.stopPrank();

        assertEq(uint256(escrow.state()), uint256(IEscrow.State.Funded));
        assertEq(usdc.balanceOf(proxy), 1000e6);

        // Release to freelancer
        vm.prank(client);
        escrow.release(free, 1000e6);

        assertEq(uint256(escrow.state()), uint256(IEscrow.State.Released));
        // Freelancer gets 99% (1% fee)
        assertEq(usdc.balanceOf(free), 990e6);
        // Fee collector gets 1%
        assertEq(usdc.balanceOf(feeCollector), 10e6);
    }

    function test_flow_refund() public {
        (, address proxy) = factory.create(client, free, address(usdc), 500e6, uint64(block.timestamp + 7 days));

        Escrow escrow = Escrow(proxy);

        // Fund
        usdc.mint(client, 500e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fund();

        // Refund
        escrow.refund();
        vm.stopPrank();

        assertEq(uint256(escrow.state()), uint256(IEscrow.State.Refunded));
        assertEq(usdc.balanceOf(client), 500e6);
    }

    function test_RevertWhen_DoubleInit() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));

        // Try to init again - should revert with WrongState
        vm.expectRevert();
        Escrow(proxy)
            .init(address(0xBAD), address(0xBAD), address(usdc), 999e6, uint64(block.timestamp), 50, address(0xBAD));
    }

    function test_RevertWhen_UnauthorizedFund() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));

        usdc.mint(address(this), 1000e6);
        usdc.approve(proxy, type(uint256).max);

        // Should revert - not client
        vm.expectRevert();
        Escrow(proxy).fund();
    }

    function test_RevertWhen_UnauthorizedRelease() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));

        Escrow escrow = Escrow(proxy);

        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fund();
        vm.stopPrank();

        // Should revert - not client
        vm.expectRevert();
        escrow.release(free, 1000e6);
    }

    function test_RevertWhen_FundWrongState() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));

        Escrow escrow = Escrow(proxy);

        // Fund first time
        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fund();

        // Try to fund again - should revert
        vm.expectRevert();
        escrow.fund();
        vm.stopPrank();
    }

    function test_RevertWhen_ReleaseAmountMismatch() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));

        Escrow escrow = Escrow(proxy);

        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fund();

        // Try to release wrong amount - should revert
        vm.expectRevert();
        escrow.release(free, 999e6);
        vm.stopPrank();
    }

    function test_RevertWhen_CreatePaused() public {
        factory.setPaused(true);
        vm.expectRevert();
        factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));
    }

    function test_RevertWhen_TokenNotAllowed() public {
        factory.setTokenAllowed(address(usdc), false);
        vm.expectRevert();
        factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));
    }

    function test_RevertWhen_FundPaused() public {
        (, address proxy) = factory.create(client, free, address(usdc), 1000e6, uint64(block.timestamp + 7 days));
        // pause after create
        factory.setFundPaused(true);
        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        vm.expectRevert(); // paused
        Escrow(proxy).fund();
        vm.stopPrank();
    }

    // ========== MILESTONE TESTS ==========

    function test_createWithMilestones() public {
        uint128[] memory budgets = new uint128[](3);
        budgets[0] = 1000e6;
        budgets[1] = 500e6;
        budgets[2] = 300e6;

        uint64[] memory deadlines = new uint64[](3);
        deadlines[0] = uint64(block.timestamp + 7 days);
        deadlines[1] = uint64(block.timestamp + 14 days);
        deadlines[2] = uint64(block.timestamp + 21 days);

        uint32[] memory reviewWindows = new uint32[](3);
        reviewWindows[0] = 7 days;
        reviewWindows[1] = 7 days;
        reviewWindows[2] = 7 days;

        bytes32[] memory metaHashes = new bytes32[](3);
        metaHashes[0] = keccak256("Milestone 1");
        metaHashes[1] = keccak256("Milestone 2");
        metaHashes[2] = keccak256("Milestone 3");

        (uint256 id, address proxy) = factory.createWithMilestones(
            client, free, address(usdc), budgets, deadlines, reviewWindows, metaHashes, IEscrow.FundingMode.FullUpfront
        );

        assertEq(id, 0);
        Escrow escrow = Escrow(proxy);
        assertEq(escrow.client(), client);
        assertEq(escrow.freelancer(), free);
        assertEq(escrow.totalAmount(), 1800e6);
        assertEq(escrow.milestoneCount(), 3);
    }

    function test_milestone_fullFlow() public {
        uint128[] memory budgets = new uint128[](2);
        budgets[0] = 1000e6;
        budgets[1] = 500e6;

        uint64[] memory deadlines = new uint64[](2);
        deadlines[0] = uint64(block.timestamp + 7 days);
        deadlines[1] = uint64(block.timestamp + 14 days);

        uint32[] memory reviewWindows = new uint32[](2);
        reviewWindows[0] = 7 days;
        reviewWindows[1] = 7 days;

        bytes32[] memory metaHashes = new bytes32[](2);
        metaHashes[0] = keccak256("MS1");
        metaHashes[1] = keccak256("MS2");

        (, address proxy) = factory.createWithMilestones(
            client, free, address(usdc), budgets, deadlines, reviewWindows, metaHashes, IEscrow.FundingMode.FullUpfront
        );
        Escrow escrow = Escrow(proxy);

        // Fund escrow
        usdc.mint(client, 1500e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fundMilestones(1500e6);
        vm.stopPrank();

        assertEq(uint256(escrow.escrowState()), uint256(IEscrow.EscrowState.Funded));

        // Freelancer submits work for milestone 0
        vm.prank(free);
        escrow.submitWork(0, keccak256("evidence1"));

        IEscrow.MilestoneView memory ms0 = escrow.getMilestone(0);
        assertEq(uint256(ms0.state), uint256(IEscrow.MilestoneState.InReview));

        // Client releases milestone 0
        vm.prank(client);
        escrow.releaseMilestone(0);

        ms0 = escrow.getMilestone(0);
        assertEq(uint256(ms0.state), uint256(IEscrow.MilestoneState.Released));
        assertEq(ms0.released, 1000e6);
        assertEq(ms0.remaining, 0);

        assertEq(usdc.balanceOf(free), 990e6);
        assertEq(usdc.balanceOf(feeCollector), 10e6);

        // Submit and release milestone 1
        vm.prank(free);
        escrow.submitWork(1, keccak256("evidence2"));

        vm.prank(client);
        escrow.releaseMilestone(1);

        assertEq(uint256(escrow.escrowState()), uint256(IEscrow.EscrowState.Closed));
        assertEq(escrow.isClosed(), true);
    }

    function test_milestone_partialRelease() public {
        uint128[] memory budgets = new uint128[](1);
        budgets[0] = 1000e6;
        uint64[] memory deadlines = new uint64[](1);
        deadlines[0] = uint64(block.timestamp + 7 days);
        uint32[] memory reviewWindows = new uint32[](1);
        reviewWindows[0] = 7 days;
        bytes32[] memory metaHashes = new bytes32[](1);
        metaHashes[0] = keccak256("MS1");

        (, address proxy) = factory.createWithMilestones(
            client, free, address(usdc), budgets, deadlines, reviewWindows, metaHashes, IEscrow.FundingMode.FullUpfront
        );
        Escrow escrow = Escrow(proxy);

        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fundMilestones(1000e6);
        vm.stopPrank();

        vm.prank(free);
        escrow.submitWork(0, keccak256("evidence"));

        // Partial release 1: 300 USDC
        vm.prank(client);
        escrow.releasePartial(0, 300e6);

        IEscrow.MilestoneView memory ms = escrow.getMilestone(0);
        assertEq(ms.released, 300e6);
        assertEq(ms.remaining, 700e6);
        assertEq(uint256(ms.state), uint256(IEscrow.MilestoneState.PartiallyReleased));
        assertEq(ms.partialCount, 1);

        // Partial release 2: 700 USDC
        vm.prank(client);
        escrow.releasePartial(0, 700e6);

        ms = escrow.getMilestone(0);
        assertEq(ms.released, 1000e6);
        assertEq(ms.remaining, 0);
        assertEq(ms.partialCount, 2);

        assertEq(usdc.balanceOf(free), 990e6);
        assertEq(usdc.balanceOf(feeCollector), 10e6);
    }

    function test_milestone_disputeResolutionByConfiguredArbitrator() public {
        uint128[] memory budgets = new uint128[](1);
        budgets[0] = 1000e6;
        uint64[] memory deadlines = new uint64[](1);
        deadlines[0] = uint64(block.timestamp + 7 days);
        uint32[] memory reviewWindows = new uint32[](1);
        reviewWindows[0] = 7 days;
        bytes32[] memory metaHashes = new bytes32[](1);
        metaHashes[0] = keccak256("Disputed milestone");

        factory.setArbitrator(arbitrator);
        (, address proxy) = factory.createWithMilestones(
            client, free, address(usdc), budgets, deadlines, reviewWindows, metaHashes, IEscrow.FundingMode.FullUpfront
        );
        Escrow escrow = Escrow(proxy);

        usdc.mint(client, 1000e6);
        vm.startPrank(client);
        usdc.approve(proxy, type(uint256).max);
        escrow.fundMilestones(1000e6);
        vm.stopPrank();

        vm.prank(free);
        escrow.submitWork(0, keccak256("evidence"));
        vm.prank(client);
        escrow.disputeMilestone(0, keccak256("scope mismatch"));

        vm.prank(arbitrator);
        escrow.resolveMilestone(0, free, 600e6);

        IEscrow.MilestoneView memory ms = escrow.getMilestone(0);
        assertEq(uint256(ms.state), uint256(IEscrow.MilestoneState.Resolved));
        assertEq(ms.released, 600e6);
        assertEq(usdc.balanceOf(free), 594e6);
        assertEq(usdc.balanceOf(client), 400e6);
        assertEq(usdc.balanceOf(feeCollector), 6e6);
        assertEq(ms.remaining, 0);
        assertTrue(escrow.isClosed());
        assertEq(escrow.escrowBalance(), 0);
    }
}
