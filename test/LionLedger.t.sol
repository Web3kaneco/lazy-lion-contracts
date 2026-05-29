// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LionLedger} from "../src/LionLedger.sol";
import {ILionLedger} from "../src/interfaces/ILionLedger.sol";

contract LionLedgerTest is Test {
    LionLedger ledger;
    address owner = address(0xA11CE);
    address operator = address(0x09E2A);
    address rando = address(0xBADBAD);

    address constant LAZY_LIONS = 0x8943C7bAC1914C9A7ABa750Bf2B6B09Fd21037E0;

    function setUp() public {
        ledger = new LionLedger(owner, operator);
    }

    function test_initial_state() public view {
        assertTrue(ledger.isOperator(operator));
        assertEq(ledger.owner(), owner);
    }

    function test_only_operator_can_record() public {
        vm.expectRevert();
        vm.prank(rando);
        ledger.record(
            LAZY_LIONS,
            4599,
            ILionLedger.EventType.PickMade,
            bytes32(uint256(1)),
            ""
        );
    }

    function test_record_increments_counter() public {
        vm.prank(operator);
        ledger.record(
            LAZY_LIONS,
            4599,
            ILionLedger.EventType.PickMade,
            bytes32(uint256(1)),
            ""
        );
        ILionLedger.Counters memory c = ledger.counters(LAZY_LIONS, 4599);
        assertEq(c.picksMade, 1);
        assertGt(c.firstSeenAt, 0);
        assertEq(c.lastEventAt, c.firstSeenAt);
    }

    function test_pick_settled_tracks_wins() public {
        vm.startPrank(operator);
        ledger.recordPickSettled(LAZY_LIONS, 4599, true, bytes32(0), "");
        ledger.recordPickSettled(LAZY_LIONS, 4599, true, bytes32(0), "");
        ledger.recordPickSettled(LAZY_LIONS, 4599, false, bytes32(0), "");
        vm.stopPrank();
        ILionLedger.Counters memory c = ledger.counters(LAZY_LIONS, 4599);
        assertEq(c.picksSettled, 3);
        assertEq(c.picksWon, 2);
    }

    function test_subscription_active_delta() public {
        vm.startPrank(operator);
        ledger.recordSubscriptionChange(
            LAZY_LIONS,
            4599,
            int32(1),
            ILionLedger.EventType.SubscriptionStarted,
            bytes32(uint256(1))
        );
        ledger.recordSubscriptionChange(
            LAZY_LIONS,
            4599,
            int32(1),
            ILionLedger.EventType.SubscriptionStarted,
            bytes32(uint256(2))
        );
        ledger.recordSubscriptionChange(
            LAZY_LIONS,
            4599,
            int32(-1),
            ILionLedger.EventType.SubscriptionEnded,
            bytes32(uint256(1))
        );
        vm.stopPrank();
        ILionLedger.Counters memory c = ledger.counters(LAZY_LIONS, 4599);
        assertEq(c.subscribersTotal, 2);
        assertEq(c.subscribersActive, 1);
    }

    function test_subscription_active_underflow_clamps_to_zero() public {
        vm.prank(operator);
        ledger.recordSubscriptionChange(
            LAZY_LIONS,
            4599,
            int32(-5),
            ILionLedger.EventType.SubscriptionEnded,
            bytes32(0)
        );
        ILionLedger.Counters memory c = ledger.counters(LAZY_LIONS, 4599);
        assertEq(c.subscribersActive, 0);
    }

    function test_owner_can_add_operator() public {
        address newOp = address(0xFFFFFF);
        vm.prank(owner);
        ledger.setOperator(newOp, true);
        assertTrue(ledger.isOperator(newOp));

        vm.prank(newOp);
        ledger.record(LAZY_LIONS, 1, ILionLedger.EventType.PickMade, bytes32(0), "");
    }

    function test_metadata_size_limit() public {
        bytes memory big = new bytes(2048);
        vm.expectRevert();
        vm.prank(operator);
        ledger.record(LAZY_LIONS, 1, ILionLedger.EventType.PickMade, bytes32(0), big);
    }
}
