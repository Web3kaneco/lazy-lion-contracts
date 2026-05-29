// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ILionLedger} from "./interfaces/ILionLedger.sol";
import {ILionEvolutionOracle} from "./interfaces/ILionEvolutionOracle.sol";

/// @title LionEvolutionOracle
/// @notice Computes earned level from LionLedger counters and signs
///         proofs that holders submit to adapter8004 on mainnet to
///         crystallize an evolution.
///
/// @dev Earned level is a pure function of the counters. The thresholds
///      live in this contract so we can tune them via a governance call
///      without redeploying the ledger.
///
///      The signed proof is EIP-712 typed data. The mainnet side
///      (a thin extension to adapter8004) recovers the signer and
///      checks it matches the trusted `signer` address.
contract LionEvolutionOracle is ILionEvolutionOracle, Ownable, EIP712 {
    // --- Storage -----------------------------------------------------

    ILionLedger public immutable ledger;

    /// @notice The wallet whose signature mainnet adapter8004 trusts.
    ///         Rotate via setSigner. The PRIVATE key for this address
    ///         lives in the oracle service (not on chain).
    address public signer;

    /// @notice How long a signed proof remains valid after issuance.
    uint64 public proofValiditySeconds;

    /// @notice Thresholds for each level. levelThresholds[N] is the
    ///         minimum cumulative "score" to reach level N. Index 0
    ///         is unused (everyone starts at level 0).
    uint32[] public levelThresholds;

    /// @notice Weights applied to each counter category when computing
    ///         the score. Adjustable so we can re-tune what activity
    ///         "counts" without a redeploy.
    struct Weights {
        uint16 pickMade;
        uint16 pickWon;
        uint16 journalEntry;
        uint16 swarmVerdict;
        uint16 artMinted;
        uint16 subscriberActive;
        uint16 toolAuthorized;
    }
    Weights public weights;

    // --- EIP-712 typehash --------------------------------------------

    /// @dev v2 typehash. adds `nonce` so the same (collection, token,
    ///      holder, level, validUntil) tuple produces a unique digest
    ///      per proof, preventing mainnet replay of identical proofs.
    bytes32 private constant EVOLUTION_PROOF_TYPEHASH = keccak256(
        "EvolutionProof(address mainnetCollection,uint256 tokenId,address holder,uint8 level,uint64 validUntil,uint256 nonce)"
    );

    // --- Timelock pattern (MED-2) ------------------------------------

    /// @notice Delay between proposing and applying sensitive changes.
    ///         Owner-tunable but never below MIN_TIMELOCK.
    uint64 public timelockDelay;
    uint64 public constant MIN_TIMELOCK = 1 hours;
    uint64 public constant MAX_TIMELOCK = 14 days;

    struct PendingSigner {
        address candidate;
        uint64 readyAt;
    }
    PendingSigner public pendingSigner;

    struct PendingWeights {
        Weights candidate;
        uint64 readyAt;
        bool exists;
    }
    PendingWeights public pendingWeights;

    struct PendingThresholds {
        uint32[] candidate;
        uint64 readyAt;
        bool exists;
    }
    PendingThresholds private _pendingThresholds;

    // --- Events ------------------------------------------------------

    event SignerUpdated(address indexed previousSigner, address indexed newSigner);
    event WeightsUpdated(Weights weights);
    event ThresholdsUpdated(uint32[] thresholds);
    event ProofValidityUpdated(uint64 seconds_);
    event TimelockDelayUpdated(uint64 seconds_);
    event SignerProposed(address indexed candidate, uint64 readyAt);
    event SignerProposalCancelled(address indexed candidate);
    event WeightsProposed(Weights candidate, uint64 readyAt);
    event WeightsProposalCancelled();
    event ThresholdsProposed(uint32[] candidate, uint64 readyAt);
    event ThresholdsProposalCancelled();

    // --- Errors ------------------------------------------------------

    error EmptyThresholds();
    error ThresholdsNotMonotonic(uint256 index);
    error NoProposal();
    error ProposalNotReady(uint64 readyAt);
    error TimelockOutOfRange(uint64 requested);

    // --- Construction ------------------------------------------------

    constructor(
        address initialOwner,
        ILionLedger initialLedger,
        address initialSigner
    ) Ownable(initialOwner) EIP712("LionEvolutionOracle", "1") {
        ledger = initialLedger;
        signer = initialSigner;
        proofValiditySeconds = 1 hours;
        timelockDelay = 24 hours;

        // Default thresholds: roughly the activity profile a casual
        // holder would hit organically. Tunable post-deploy.
        // Must stay strictly increasing. earnedLevel() breaks on the
        // first miss, so an unsorted list would silently cap levels.
        levelThresholds = [
            0, // level 0 (everyone)
            10, // level 1
            50, // level 2
            150, // level 3
            350, // level 4
            700, // level 5
            1300, // level 6
            2200, // level 7
            3500, // level 8
            5500, // level 9
            8500 // level 10
        ];
        _requireMonotonic(levelThresholds);

        weights = Weights({
            pickMade: 1,
            pickWon: 3,
            journalEntry: 2,
            swarmVerdict: 5,
            artMinted: 8,
            subscriberActive: 15,
            toolAuthorized: 10
        });

        emit SignerUpdated(address(0), initialSigner);
        emit WeightsUpdated(weights);
        emit ThresholdsUpdated(levelThresholds);
        emit ProofValidityUpdated(proofValiditySeconds);
    }

    // --- Owner controls (instant) ------------------------------------
    // These two are low-risk and apply immediately. The sensitive
    // rotations (signer, weights, thresholds) are timelocked via the
    // propose/cancel/apply sections below.

    function setProofValidity(uint64 seconds_) external onlyOwner {
        proofValiditySeconds = seconds_;
        emit ProofValidityUpdated(seconds_);
    }

    function setTimelockDelay(uint64 seconds_) external onlyOwner {
        if (seconds_ < MIN_TIMELOCK || seconds_ > MAX_TIMELOCK) {
            revert TimelockOutOfRange(seconds_);
        }
        timelockDelay = seconds_;
        emit TimelockDelayUpdated(seconds_);
    }

    // --- Signer: propose / cancel / apply ----------------------------

    function proposeSigner(address candidate) external onlyOwner {
        uint64 readyAt = uint64(block.timestamp) + timelockDelay;
        pendingSigner = PendingSigner({candidate: candidate, readyAt: readyAt});
        emit SignerProposed(candidate, readyAt);
    }

    function cancelSignerProposal() external onlyOwner {
        emit SignerProposalCancelled(pendingSigner.candidate);
        delete pendingSigner;
    }

    function applySigner() external onlyOwner {
        PendingSigner memory p = pendingSigner;
        if (p.readyAt == 0) revert NoProposal();
        if (block.timestamp < p.readyAt) revert ProposalNotReady(p.readyAt);
        emit SignerUpdated(signer, p.candidate);
        signer = p.candidate;
        delete pendingSigner;
    }

    // --- Weights: propose / cancel / apply ---------------------------

    function proposeWeights(Weights calldata candidate) external onlyOwner {
        pendingWeights = PendingWeights({
            candidate: candidate,
            readyAt: uint64(block.timestamp) + timelockDelay,
            exists: true
        });
        emit WeightsProposed(candidate, pendingWeights.readyAt);
    }

    function cancelWeightsProposal() external onlyOwner {
        delete pendingWeights;
        emit WeightsProposalCancelled();
    }

    function applyWeights() external onlyOwner {
        PendingWeights memory p = pendingWeights;
        if (!p.exists) revert NoProposal();
        if (block.timestamp < p.readyAt) revert ProposalNotReady(p.readyAt);
        weights = p.candidate;
        delete pendingWeights;
        emit WeightsUpdated(p.candidate);
    }

    // --- Thresholds: propose / cancel / apply ------------------------

    function proposeThresholds(uint32[] calldata candidate) external onlyOwner {
        if (candidate.length == 0) revert EmptyThresholds();
        _requireMonotonic(candidate);
        _pendingThresholds.candidate = candidate;
        _pendingThresholds.readyAt = uint64(block.timestamp) + timelockDelay;
        _pendingThresholds.exists = true;
        emit ThresholdsProposed(candidate, _pendingThresholds.readyAt);
    }

    function cancelThresholdsProposal() external onlyOwner {
        delete _pendingThresholds;
        emit ThresholdsProposalCancelled();
    }

    function applyThresholds() external onlyOwner {
        if (!_pendingThresholds.exists) revert NoProposal();
        if (block.timestamp < _pendingThresholds.readyAt) {
            revert ProposalNotReady(_pendingThresholds.readyAt);
        }
        levelThresholds = _pendingThresholds.candidate;
        emit ThresholdsUpdated(_pendingThresholds.candidate);
        delete _pendingThresholds;
    }

    function pendingThresholds() external view returns (uint32[] memory, uint64, bool) {
        return (_pendingThresholds.candidate, _pendingThresholds.readyAt, _pendingThresholds.exists);
    }

    /// @dev Thresholds must be strictly increasing because earnedLevel()
    ///      stops at the first threshold the score doesn't meet. An
    ///      unsorted list would silently cap a Lion below its true level.
    function _requireMonotonic(uint32[] memory t) private pure {
        for (uint256 i = 1; i < t.length; i++) {
            if (t[i] <= t[i - 1]) revert ThresholdsNotMonotonic(i);
        }
    }

    // --- Score + level computation -----------------------------------

    /// @notice Score is a weighted sum of counters. Deterministic.
    function score(address mainnetCollection, uint256 tokenId)
        public
        view
        returns (uint256)
    {
        ILionLedger.Counters memory c = ledger.counters(mainnetCollection, tokenId);
        Weights memory w = weights;
        unchecked {
            return uint256(c.picksMade) * w.pickMade
                + uint256(c.picksWon) * w.pickWon
                + uint256(c.journalEntries) * w.journalEntry
                + uint256(c.swarmVerdicts) * w.swarmVerdict
                + uint256(c.artMinted) * w.artMinted
                + uint256(c.subscribersActive) * w.subscriberActive
                + uint256(c.toolsAuthorized) * w.toolAuthorized;
        }
    }

    /// @inheritdoc ILionEvolutionOracle
    function earnedLevel(address mainnetCollection, uint256 tokenId)
        public
        view
        returns (uint8)
    {
        uint256 s = score(mainnetCollection, tokenId);
        uint256 n = levelThresholds.length;
        uint8 best = 0;
        for (uint256 i = 0; i < n; i++) {
            if (s >= levelThresholds[i]) {
                best = uint8(i);
            } else {
                break;
            }
        }
        return best;
    }

    // --- Proof issuance ----------------------------------------------

    /// @inheritdoc ILionEvolutionOracle
    /// @dev Returns ONLY the inputs the off-chain oracle service needs
    ///      to construct a proof. The actual signature is produced
    ///      off-chain by the signer's private key. No signature is
    ///      returned from this contract.
    function getProofShape(
        address mainnetCollection,
        uint256 tokenId,
        address holder
    )
        external
        view
        returns (uint8 level, uint64 validUntil)
    {
        level = earnedLevel(mainnetCollection, tokenId);
        validUntil = uint64(block.timestamp) + proofValiditySeconds;
        holder; // included for ABI parity with future on-chain binding
    }

    /// @notice Compute the EIP-712 digest the oracle service signs.
    ///         A nonce binds the digest uniquely per proof issuance so
    ///         that re-evolving to the same level produces a fresh
    ///         digest (prevents mainnet replay of stale proofs).
    function evolutionDigest(
        address mainnetCollection,
        uint256 tokenId,
        address holder,
        uint8 level,
        uint64 validUntil,
        uint256 nonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                EVOLUTION_PROOF_TYPEHASH,
                mainnetCollection,
                tokenId,
                holder,
                level,
                validUntil,
                nonce
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /// @notice Verify a signature on-chain. Used by tests and any
    ///         consumer that wants to validate a proof without going
    ///         to mainnet.
    function verifyProof(
        address mainnetCollection,
        uint256 tokenId,
        address holder,
        uint8 level,
        uint64 validUntil,
        uint256 nonce,
        bytes calldata signature
    ) external view returns (bool) {
        if (block.timestamp > validUntil) return false;
        bytes32 digest = evolutionDigest(
            mainnetCollection, tokenId, holder, level, validUntil, nonce
        );
        address recovered = ECDSA.recover(digest, signature);
        return recovered == signer && recovered != address(0);
    }
}
