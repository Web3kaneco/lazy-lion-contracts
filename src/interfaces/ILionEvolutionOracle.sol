// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILionEvolutionOracle
/// @notice Reads the LionLedger and produces signed proofs of earned
///         level that holders submit to adapter8004 on mainnet.
interface ILionEvolutionOracle {
    /// @notice Compute the earned level for a Lion from its current
    ///         ledger counters. Pure view function — no signature.
    function earnedLevel(address mainnetCollection, uint256 tokenId)
        external
        view
        returns (uint8);

    /// @notice Return the shape of an evolution proof — what the
    ///         off-chain oracle service needs to produce a signature
    ///         for. The actual ECDSA signature is NOT returned here
    ///         (the private key is held off-chain). Callers use this
    ///         to compute the digest the oracle service will sign.
    /// @return level The earned level being attested to.
    /// @return validUntil Unix timestamp after which the proof expires.
    function getProofShape(
        address mainnetCollection,
        uint256 tokenId,
        address holder
    )
        external
        view
        returns (uint8 level, uint64 validUntil);
}
