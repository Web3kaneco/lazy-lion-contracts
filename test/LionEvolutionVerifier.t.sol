// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LionEvolutionVerifier} from "../src/LionEvolutionVerifier.sol";
import {LionEvolutionOracle} from "../src/LionEvolutionOracle.sol";
import {LionLedger} from "../src/LionLedger.sol";

/// @notice Verifier tests. The central property is cross-chain EIP-712
///         correctness: a real oracle (deployed here, computing its own
///         domain separator) produces a digest; the verifier built with
///         that oracle's chainId+address must accept the signature, and a
///         verifier built with the WRONG domain must reject it.
contract LionEvolutionVerifierTest is Test {
    LionLedger ledger;
    LionEvolutionOracle oracle;
    LionEvolutionVerifier verifier;

    address owner = address(0xA11CE);
    address operator = address(0x09E2A);
    uint256 signerKey = 0xBEEF;
    address signer;

    address holder = address(0xCAFE);
    address constant LAZY_LIONS = 0x8943C7bAC1914C9A7ABa750Bf2B6B09Fd21037E0;
    uint256 constant TOKEN = 4599;

    function setUp() public {
        signer = vm.addr(signerKey);
        ledger = new LionLedger(owner, operator);
        oracle = new LionEvolutionOracle(owner, ledger, signer);
        // Build the verifier against the oracle's ACTUAL domain facts:
        // its chainId (block.chainid in this test) and its address.
        verifier = new LionEvolutionVerifier(
            owner,
            signer,
            block.chainid,
            address(oracle)
        );
    }

    // --- Helpers -----------------------------------------------------

    function _sign(
        uint8 level,
        uint64 validUntil,
        uint256 nonce,
        address who
    ) internal view returns (bytes memory sig, bytes32 digest) {
        // Use the ORACLE's own digest function. the real signing target.
        digest = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, who, level, validUntil, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // --- Tests -------------------------------------------------------

    function test_verifier_digest_matches_oracle_digest() public view {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        bytes32 oracleDigest = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, 3, validUntil, 7
        );
        bytes32 verifierDigest = verifier.digest(
            LAZY_LIONS, TOKEN, holder, 3, validUntil, 7
        );
        assertEq(verifierDigest, oracleDigest, "digests must match byte-for-byte");
    }

    function test_happy_path_evolve_commits_level() public {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        vm.prank(holder);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);

        assertEq(verifier.committedLevel(LAZY_LIONS, TOKEN), 3);
        assertEq(verifier.levelOf(LAZY_LIONS, TOKEN), 3);
    }

    function test_wrong_domain_signature_is_rejected() public {
        // A verifier built with the WRONG oracle domain (different address)
        // must reject a signature made against the real oracle domain. This
        // is the cross-chain regression test.
        LionEvolutionVerifier wrong = new LionEvolutionVerifier(
            owner,
            signer,
            block.chainid,
            address(0xDEAD) // wrong verifyingContract in the domain
        );
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.InvalidSignature.selector);
        wrong.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_wrong_chainid_in_domain_is_rejected() public {
        LionEvolutionVerifier wrong = new LionEvolutionVerifier(
            owner,
            signer,
            block.chainid + 1, // wrong chainId in the domain
            address(oracle)
        );
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.InvalidSignature.selector);
        wrong.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_wrong_signer_key_is_rejected() public {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        bytes32 d = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, 3, validUntil, 1
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, d); // not the trusted key
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.InvalidSignature.selector);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_expired_proof_is_rejected() public {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        vm.warp(validUntil + 1);
        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.ProofExpired.selector);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_replay_is_rejected() public {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        vm.prank(holder);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);

        // Second submit of the same proof reverts as used.
        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.ProofAlreadyUsed.selector);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_non_increasing_level_is_rejected() public {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        // First commit level 5.
        (bytes memory sig5, ) = _sign(5, validUntil, 1, holder);
        vm.prank(holder);
        verifier.evolve(LAZY_LIONS, TOKEN, 5, validUntil, 1, sig5);

        // Now a valid proof for level 3 (lower) must be rejected.
        (bytes memory sig3, ) = _sign(3, validUntil, 2, holder);
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                LionEvolutionVerifier.NotAnIncrease.selector,
                uint8(5),
                uint8(3)
            )
        );
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 2, sig3);
    }

    function test_holder_mismatch_frontrun_is_rejected() public {
        // Proof issued for `holder`, but a different address submits. Since
        // the digest binds msg.sender, the attacker's call recovers a digest
        // for the WRONG holder and the signature fails to verify.
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory sig, ) = _sign(3, validUntil, 1, holder);

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(LionEvolutionVerifier.InvalidSignature.selector);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 1, sig);
    }

    function test_signer_rotation() public {
        uint256 newKey = 0xF00D;
        address newSigner = vm.addr(newKey);

        // Old key still works before rotation.
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        (bytes memory oldSig, ) = _sign(2, validUntil, 1, holder);
        vm.prank(holder);
        verifier.evolve(LAZY_LIONS, TOKEN, 2, validUntil, 1, oldSig);

        // Rotate.
        vm.prank(owner);
        verifier.setOracleSigner(newSigner);
        assertEq(verifier.oracleSigner(), newSigner);

        // Old key now rejected.
        (bytes memory oldSig2, ) = _sign(3, validUntil, 2, holder);
        vm.prank(holder);
        vm.expectRevert(LionEvolutionVerifier.InvalidSignature.selector);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 2, oldSig2);

        // New key accepted.
        bytes32 d = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, 3, validUntil, 3
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newKey, d);
        bytes memory newSig = abi.encodePacked(r, s, v);
        vm.prank(holder);
        verifier.evolve(LAZY_LIONS, TOKEN, 3, validUntil, 3, newSig);
        assertEq(verifier.committedLevel(LAZY_LIONS, TOKEN), 3);
    }

    function test_isValidProof_view() public view {
        uint64 validUntil = uint64(block.timestamp + 1 hours);
        bytes32 d = oracle.evolutionDigest(
            LAZY_LIONS, TOKEN, holder, 4, validUntil, 9
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, d);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertTrue(
            verifier.isValidProof(LAZY_LIONS, TOKEN, holder, 4, validUntil, 9, sig)
        );
        assertFalse(
            verifier.isValidProof(LAZY_LIONS, TOKEN, holder, 5, validUntil, 9, sig)
        );
    }

    function test_constructor_rejects_zero_signer() public {
        vm.expectRevert(LionEvolutionVerifier.ZeroSigner.selector);
        new LionEvolutionVerifier(owner, address(0), block.chainid, address(oracle));
    }
}
