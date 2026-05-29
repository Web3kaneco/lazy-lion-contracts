// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title LionEvolutionVerifier
/// @notice Mainnet contract that verifies an oracle-signed EIP-712 evolution
///         proof and crystallizes the earned level onto the Lion's mainnet
///         identity. Closes go-live #6 (the Evolve flow).
///
/// @dev CROSS-CHAIN EIP-712. read carefully.
///
///      The proof is signed by `LionEvolutionOracle` which lives on BASE,
///      using its OWN EIP-712 domain:
///        name="LionEvolutionOracle", version="1", chainId=<Base>,
///        verifyingContract=<oracle address on Base>.
///
///      This verifier runs on Ethereum MAINNET. It therefore CANNOT use
///      OpenZeppelin's EIP712/_hashTypedDataV4, which would bind the domain
///      to mainnet's chainId and this contract's own address. that domain
///      would not match what the oracle signed, and every recover would
///      fail. Instead we reconstruct the oracle's BASE domain separator
///      manually from constructor-supplied facts (oracle chainId + address).
///
///      The struct typehash is copied verbatim from
///      LionEvolutionOracle.EVOLUTION_PROOF_TYPEHASH. If the oracle's
///      typehash ever changes, this MUST change in lockstep.
contract LionEvolutionVerifier is Ownable {
    // --- EIP-712 (oracle's Base domain, reconstructed) ---------------

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @dev Verbatim copy of LionEvolutionOracle.EVOLUTION_PROOF_TYPEHASH.
    bytes32 private constant EVOLUTION_PROOF_TYPEHASH = keccak256(
        "EvolutionProof(address mainnetCollection,uint256 tokenId,address holder,uint8 level,uint64 validUntil,uint256 nonce)"
    );

    /// @notice The oracle's EIP-712 domain separator, computed once at
    ///         construction from the oracle's Base deployment facts. This is
    ///         the domain the signatures were produced against.
    bytes32 public immutable oracleDomainSeparator;

    /// @notice Facts about the oracle on Base, kept for transparency.
    uint256 public immutable oracleChainId;
    address public immutable oracleAddress;

    // --- Trusted signer ----------------------------------------------

    /// @notice The address whose signature this verifier trusts. Mirrors
    ///         the oracle's `signer`; rotate the two together.
    address public oracleSigner;

    // --- State this verifier owns ------------------------------------

    /// @notice collection => tokenId => committed level. This verifier is
    ///         the mainnet source of truth for a Lion's committed level.
    mapping(address => mapping(uint256 => uint8)) public committedLevel;

    /// @notice Consumed proof digests (replay protection on mainnet). The
    ///         oracle's nonce makes each digest unique; we reject any digest
    ///         already used to commit here.
    mapping(bytes32 => bool) public usedDigest;

    // --- Events ------------------------------------------------------

    event Evolved(
        address indexed mainnetCollection,
        uint256 indexed tokenId,
        address indexed holder,
        uint8 level,
        uint256 nonce
    );
    event OracleSignerUpdated(address indexed previous, address indexed current);

    // --- Errors ------------------------------------------------------

    error ProofExpired();
    error ProofAlreadyUsed();
    error InvalidSignature();
    error NotAnIncrease(uint8 current, uint8 proposed);
    error HolderMismatch(address expected, address caller);
    error ZeroSigner();

    // --- Construction ------------------------------------------------

    /// @param initialOwner       Owner that can rotate the trusted signer.
    /// @param initialOracleSigner The signer address the oracle uses.
    /// @param oracleChainId_     The chainId the oracle is deployed on (Base
    ///                           mainnet = 8453, Base sepolia = 84532).
    /// @param oracleAddress_     The oracle contract address on that chain.
    constructor(
        address initialOwner,
        address initialOracleSigner,
        uint256 oracleChainId_,
        address oracleAddress_
    ) Ownable(initialOwner) {
        if (initialOracleSigner == address(0)) revert ZeroSigner();
        oracleSigner = initialOracleSigner;
        oracleChainId = oracleChainId_;
        oracleAddress = oracleAddress_;

        // Reconstruct the EXACT domain the oracle signs under. name/version
        // match LionEvolutionOracle's EIP712("LionEvolutionOracle", "1").
        oracleDomainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("LionEvolutionOracle")),
                keccak256(bytes("1")),
                oracleChainId_,
                oracleAddress_
            )
        );

        emit OracleSignerUpdated(address(0), initialOracleSigner);
    }

    // --- Owner controls ----------------------------------------------

    /// @notice Rotate the trusted signer. Keep in sync with the oracle's
    ///         own signer rotation on Base.
    function setOracleSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroSigner();
        emit OracleSignerUpdated(oracleSigner, newSigner);
        oracleSigner = newSigner;
    }

    // --- Digest ------------------------------------------------------

    /// @notice Reconstruct the EIP-712 digest the oracle signed for this
    ///         proof. Pure given the immutable oracle domain separator.
    function digest(
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
        return keccak256(
            abi.encodePacked("\x19\x01", oracleDomainSeparator, structHash)
        );
    }

    /// @notice View-only check that a signature is valid for these inputs.
    ///         Does not consider replay or expiry. those are enforced in
    ///         evolve(). Useful for off-chain pre-flight.
    function isValidProof(
        address mainnetCollection,
        uint256 tokenId,
        address holder,
        uint8 level,
        uint64 validUntil,
        uint256 nonce,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 d = digest(
            mainnetCollection, tokenId, holder, level, validUntil, nonce
        );
        address recovered = ECDSA.recover(d, signature);
        return recovered == oracleSigner && recovered != address(0);
    }

    // --- Evolve ------------------------------------------------------

    /// @notice Crystallize an earned level onto the Lion. The caller MUST be
    ///         the `holder` the proof was issued for (front-run protection).
    ///         The level must strictly increase. The proof must be unexpired,
    ///         signed by the trusted oracle signer, and unused.
    function evolve(
        address mainnetCollection,
        uint256 tokenId,
        uint8 level,
        uint64 validUntil,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (block.timestamp > validUntil) revert ProofExpired();

        // The proof binds a specific holder. only they may submit it, so a
        // third party cannot front-run someone else's signed proof.
        bytes32 d = digest(
            mainnetCollection, tokenId, msg.sender, level, validUntil, nonce
        );
        if (usedDigest[d]) revert ProofAlreadyUsed();

        address recovered = ECDSA.recover(d, signature);
        if (recovered != oracleSigner || recovered == address(0)) {
            revert InvalidSignature();
        }

        uint8 current = committedLevel[mainnetCollection][tokenId];
        if (level <= current) revert NotAnIncrease(current, level);

        usedDigest[d] = true;
        committedLevel[mainnetCollection][tokenId] = level;

        emit Evolved(mainnetCollection, tokenId, msg.sender, level, nonce);
    }

    /// @notice Convenience reader for the site.
    function levelOf(address mainnetCollection, uint256 tokenId)
        external
        view
        returns (uint8)
    {
        return committedLevel[mainnetCollection][tokenId];
    }
}
