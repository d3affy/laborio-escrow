// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {Errors} from "../src/libs/Errors.sol";
import {MockUSDC} from "./Escrow.t.sol";

contract MilestoneFundingTest is Test {
    address internal freelancer = makeAddr("freelancer");
    MockUSDC internal token;
    EscrowFactory internal factory;

    function setUp() public {
        token = new MockUSDC();
        factory = new EscrowFactory(address(new Escrow()), makeAddr("collector"), 100, 1e6);
        factory.setTokenAllowed(address(token), true);
        token.mint(address(this), 200e6);
    }

    function create(IEscrow.FundingMode mode) internal returns (Escrow escrow) {
        uint128[] memory budgets = new uint128[](2);
        budgets[0] = 100e6;
        budgets[1] = 100e6;
        (, address proxy) = factory.createWithMilestones(
            address(this), freelancer, address(token), budgets, new uint64[](2), new uint32[](2), new bytes32[](2), mode
        );
        token.approve(proxy, 200e6);
        return Escrow(proxy);
    }

    function test_IndependentlyFundedMilestonesSettleToZero() public {
        Escrow escrow = create(IEscrow.FundingMode.PerMilestone);
        escrow.fundMilestone(1, 40e6);
        escrow.fundMilestone(1, 60e6);
        vm.prank(freelancer);
        vm.expectRevert(Errors.InsufficientFunding.selector);
        escrow.submitWork(0, keccak256("first deliverable"));

        vm.prank(freelancer);
        escrow.submitWork(1, keccak256("second deliverable"));
        escrow.releasePartial(1, 40e6);
        escrow.releaseMilestone(1);
        assertEq(uint256(escrow.getMilestone(1).state), uint256(IEscrow.MilestoneState.Released));
        escrow.fundMilestone(0, 100e6);
        escrow.refundMilestone(0);
        assertTrue(escrow.isClosed());
        assertEq(token.balanceOf(freelancer), 99e6);
        assertEq(escrow.escrowBalance(), 0);
    }

    function test_ClientCanWithdrawAnIncompleteDeposit() public {
        Escrow escrow = create(IEscrow.FundingMode.PerMilestone);
        escrow.fundMilestone(1, 40e6);
        escrow.withdrawIncompleteFunding(1);
        assertEq(escrow.funded(), 0);
        assertEq(token.balanceOf(address(this)), 200e6);

        escrow = create(IEscrow.FundingMode.FullUpfront);
        escrow.fundMilestones(50e6);
        escrow.withdrawIncompleteFunding(0);
        token.approve(address(escrow), 200e6);
        escrow.topUp(200e6);
        escrow.refundMilestone(0);
        escrow.refundMilestone(1);
        assertEq(token.balanceOf(address(this)), 200e6);
        assertTrue(escrow.isClosed());
    }

    function test_FundingPauseAndFactoryIds() public {
        Escrow first = create(IEscrow.FundingMode.FullUpfront);
        Escrow second = create(IEscrow.FundingMode.PerMilestone);
        assertEq(first.escrowId(), 0);
        assertEq(second.escrowId(), 1);
        factory.setFundPaused(true);
        vm.expectRevert(Errors.Paused.selector);
        first.fundMilestones(100e6);
        vm.expectRevert(Errors.Paused.selector);
        second.fundMilestone(0, 100e6);
        factory.setFundPaused(false);
        second.fundMilestone(0, 100e6);
        assertEq(second.escrowBalance(), 100e6);
    }
}
