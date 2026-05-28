// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LionLedger} from "../src/LionLedger.sol";
import {LionEvolutionOracle} from "../src/LionEvolutionOracle.sol";
import {ILionLedger} from "../src/interfaces/ILionLedger.sol";

contract LionEvolutionOracleTest is Test {
    LionLedger ledger;
    LionEvolutionOracle oracle;

    address owner = address(0xA11CE);
    address operator = address(0x0PE2A);
    uint256 signerKey = 0xBEEF;
    address signer;

    address constant LAZY_LIONS = 0x8943C7bAC1914C9A7ABa750Bf2B6B09Fd21037E0;
    uint256 constant TOKEN = 4599;

    function setUp() public {
        signer = vm.addr(signerKey);
        ledger = new LionLedger(owner, operator);
        oracle = new LionEvolutionOracle(owner, ledger, signer);
    }

    function _bumpActivity(uint32 picks, uint32 wins, uint32 swarms) internal {
        vm.startPrank(operator);
        for (uint32 i = 0; i < picks; i++) {
            ledger.record(LAZY_LIONS, TOKEN, ILionLedger.EventType.PickMade, bytes32(0), "");
        }
        for (uint32 i = 0; i < wins; i++) {
            ledger.recordPickSettled(LAZY_LIONS, TOKEN, true, bytes32(0), "");
        }
        for (uint32 i = 0; i < swarms; i++) {
            ledger.record(LAZY_LIONS, TOKEN, ILionLedger.EventType.SwarmVerdict, bytes32(0), "");
        }
        vm.stopPrank();
    }

    function test_initial_level_is_zero() public view {
        assertEq(oracle.earnedLevel(LAZY_LIONS, TOKEN), 0);
    }

    function test_level_progresses_with_activity() public {
        // Default weights: pickMade=1, pickWon=3, swarmVerdict=5
        // Default thresholds: [0, 10, 50, 150, 350, ...]
        _bumpActivity(15, 0, 0); // score 15 → level 1
        assertEq(oracle.earnedLevel(LAZY_LIONS, TOKEN), 1);

        _bumpActivity(0, 5, 5); // +15 (wins) + 25 (swarms) = +40 → score 55 → level 2
        assertEq(oracle.earnedLevel(LAZY_LIONS, TOKEN), 2);
    }

    function test_signature_verifies() public {
        _bumpActivity(60, 0, 0); // score 60 → level 2
        uint8 level = oracle.earnedLevel(LAZY_LIONS, TOKEN);
        address holder = address(0xCAFE);
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        uint256 nonce = 42;

        bytes32 digest = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, level, validUntil, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(
            oracle.verifyProof(LAZY_LIONS, TOKEN, holder, level, validUntil, nonce, sig)
        );
    }

    function test_signature_from_wrong_key_fails() public {
        uint8 level = 0;
        address holder = address(0xCAFE);
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        uint256 nonce = 1;
        bytes32 digest = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, level, validUntil, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertFalse(
            oracle.verifyProof(LAZY_LIONS, TOKEN, holder, level, validUntil, nonce, sig)
        );
    }

    function test_expired_proof_fails() public {
        uint8 level = 0;
        address holder = address(0xCAFE);
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        uint256 nonce = 1;
        bytes32 digest = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, level, validUntil, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.warp(validUntil + 1);
        assertFalse(
            oracle.verifyProof(LAZY_LIONS, TOKEN, holder, level, validUntil, nonce, sig)
        );
    }

    function test_signer_rotation_requires_timelock() public {
        address newSigner = address(0xBEEFEE);
        vm.prank(owner);
        oracle.proposeSigner(newSigner);
        // immediately applying should revert
        vm.expectRevert();
        vm.prank(owner);
        oracle.applySigner();
        // warp past the delay
        vm.warp(block.timestamp + 25 hours);
        vm.prank(owner);
        oracle.applySigner();
        assertEq(oracle.signer(), newSigner);
    }

    function test_signer_proposal_can_be_cancelled() public {
        address newSigner = address(0xBEEFEE);
        vm.prank(owner);
        oracle.proposeSigner(newSigner);
        vm.prank(owner);
        oracle.cancelSignerProposal();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert();
        vm.prank(owner);
        oracle.applySigner();
    }
}
