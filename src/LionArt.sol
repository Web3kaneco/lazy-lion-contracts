// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ILionRenderer} from "./interfaces/ILionRenderer.sol";
import {ILionLedger} from "./interfaces/ILionLedger.sol";

/// @title LionArt
/// @notice ERC-721 collection of art pieces minted from Lion activity
///         snapshots. Each piece is bound to a mainnet Lion (by
///         collection address + token id) and frozen at mint time.
///
/// @dev Mint authorization: the holder of the mainnet Lion signs an
///      EIP-712 mint intent which this contract verifies. The signer's
///      mainnet ownership is verified off-chain by the LazyLionAgents
///      backend (which then submits the mint tx). a future version
///      can plug in a Base→mainnet ownership oracle for fully
///      trustless verification.
///
/// `tokenURI(id)` returns a full data URI with embedded SVG produced
/// by the LionRenderer contract. No external dependencies.
contract LionArt is ERC721, Ownable, EIP712 {
    using Strings for uint256;

    // --- Storage -----------------------------------------------------

    /// @notice Frozen inputs for each minted piece.
    struct Piece {
        address mainnetCollection;
        uint256 mainnetTokenId;
        bytes bitmap;
        bytes32 activitySeed;
        uint8 level;
        uint8 eventKind;
        bytes32 eventData;
        string name;
        uint64 mintedAt;
    }

    /// @dev tokenId → Piece
    mapping(uint256 => Piece) public pieces;

    /// @notice Renderer for tokenURI. Owner can swap in a v2 renderer
    ///         later without redeploying this contract.
    ILionRenderer public renderer;

    /// @notice Ledger to log art-minted events to.
    ILionLedger public ledger;

    /// @notice Operator wallet that submits mints on behalf of holders
    ///         after verifying mainnet ownership.
    address public operator;

    /// @notice Timelock-pending operator and renderer rotations (MED-4).
    uint64 public constant TIMELOCK_DELAY = 24 hours;
    address public pendingOperator;
    uint64 public pendingOperatorReadyAt;
    address public pendingRenderer;
    uint64 public pendingRendererReadyAt;

    /// @notice Per-holder nonce tracking. Each mint must use a unique
    ///         nonce per holder. MED-5: enforces strict uniqueness.
    ///         This is the sole anti-replay guard. the signed digest
    ///         includes the nonce, so a unique (holder, nonce) pair
    ///         uniquely identifies every intent.
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    uint256 private _nextTokenId;

    // --- EIP-712 -----------------------------------------------------

    /// @dev v2 typehash. adds `renderer` so a holder's signed intent
    ///      is bound to the renderer version that was current when they
    ///      signed. Prevents intents from being applied under a future
    ///      renderer the holder didn't see.
    bytes32 private constant MINT_INTENT_TYPEHASH = keccak256(
        "MintIntent(address mainnetCollection,uint256 mainnetTokenId,address holder,uint8 eventKind,bytes32 eventData,bytes32 activitySeedHash,bytes32 bitmapHash,uint8 level,uint256 nonce,uint64 validUntil,address renderer)"
    );

    // --- Events ------------------------------------------------------

    event PieceMinted(
        uint256 indexed tokenId,
        address indexed mainnetCollection,
        uint256 indexed mainnetTokenId,
        address recipient,
        uint8 eventKind
    );
    event RendererUpdated(address indexed previous, address indexed current);
    event OperatorUpdated(address indexed previous, address indexed current);
    event OperatorProposed(address indexed candidate, uint64 readyAt);
    event RendererProposed(address indexed candidate, uint64 readyAt);
    event LedgerWriteFailed(
        uint256 indexed tokenId,
        address indexed mainnetCollection,
        uint256 indexed mainnetTokenId
    );

    // --- Errors ------------------------------------------------------

    error InvalidSignature();
    error IntentExpired();
    error NotOperator();
    error InvalidBitmapLength();
    error NonceAlreadyUsed();
    error NoProposal();
    error ProposalNotReady(uint64 readyAt);

    // --- Construction ------------------------------------------------

    constructor(
        address initialOwner,
        ILionRenderer initialRenderer,
        ILionLedger initialLedger,
        address initialOperator
    )
        ERC721("Lazy Lion Ledger Art", "LLLA")
        Ownable(initialOwner)
        EIP712("LionArt", "1")
    {
        renderer = initialRenderer;
        ledger = initialLedger;
        operator = initialOperator;
        _nextTokenId = 1;
    }

    // --- Owner controls (timelocked, MED-4) --------------------------

    function proposeOperator(address candidate) external onlyOwner {
        pendingOperator = candidate;
        pendingOperatorReadyAt = uint64(block.timestamp) + TIMELOCK_DELAY;
        emit OperatorProposed(candidate, pendingOperatorReadyAt);
    }

    function applyOperator() external onlyOwner {
        if (pendingOperatorReadyAt == 0) revert NoProposal();
        if (block.timestamp < pendingOperatorReadyAt) {
            revert ProposalNotReady(pendingOperatorReadyAt);
        }
        emit OperatorUpdated(operator, pendingOperator);
        operator = pendingOperator;
        pendingOperator = address(0);
        pendingOperatorReadyAt = 0;
    }

    function cancelOperatorProposal() external onlyOwner {
        pendingOperator = address(0);
        pendingOperatorReadyAt = 0;
    }

    function proposeRenderer(ILionRenderer candidate) external onlyOwner {
        pendingRenderer = address(candidate);
        pendingRendererReadyAt = uint64(block.timestamp) + TIMELOCK_DELAY;
        emit RendererProposed(address(candidate), pendingRendererReadyAt);
    }

    function applyRenderer() external onlyOwner {
        if (pendingRendererReadyAt == 0) revert NoProposal();
        if (block.timestamp < pendingRendererReadyAt) {
            revert ProposalNotReady(pendingRendererReadyAt);
        }
        emit RendererUpdated(address(renderer), pendingRenderer);
        renderer = ILionRenderer(pendingRenderer);
        pendingRenderer = address(0);
        pendingRendererReadyAt = 0;
    }

    function cancelRendererProposal() external onlyOwner {
        pendingRenderer = address(0);
        pendingRendererReadyAt = 0;
    }

    // --- Mint --------------------------------------------------------

    /// @notice Mint a piece. Called by the operator after verifying:
    ///   - The holder's signature on the mint intent
    ///   - The holder's current mainnet ownership of the Lion
    /// @dev `bitmap` is the full 200-byte bitmap at the time of mint;
    ///      we hash it and check against the signed bitmapHash so the
    ///      holder can't be tricked into authorizing a different art.
    function mint(
        address holder,
        Piece calldata piece,
        uint256 nonce,
        uint64 validUntil,
        bytes calldata holderSignature
    ) external returns (uint256 tokenId) {
        if (msg.sender != operator) revert NotOperator();
        if (block.timestamp > validUntil) revert IntentExpired();
        if (piece.bitmap.length != 200) revert InvalidBitmapLength();
        if (usedNonces[holder][nonce]) revert NonceAlreadyUsed();

        bytes32 bitmapHash = keccak256(piece.bitmap);
        bytes32 intentStruct = keccak256(
            abi.encode(
                MINT_INTENT_TYPEHASH,
                piece.mainnetCollection,
                piece.mainnetTokenId,
                holder,
                piece.eventKind,
                piece.eventData,
                piece.activitySeed,
                bitmapHash,
                piece.level,
                nonce,
                validUntil,
                address(renderer)
            )
        );
        bytes32 digest = _hashTypedDataV4(intentStruct);
        address recovered = ECDSA.recover(digest, holderSignature);
        if (recovered != holder || recovered == address(0)) revert InvalidSignature();

        usedNonces[holder][nonce] = true;

        tokenId = _nextTokenId++;
        pieces[tokenId] = Piece({
            mainnetCollection: piece.mainnetCollection,
            mainnetTokenId: piece.mainnetTokenId,
            bitmap: piece.bitmap,
            activitySeed: piece.activitySeed,
            level: piece.level,
            eventKind: piece.eventKind,
            eventData: piece.eventData,
            name: piece.name,
            mintedAt: uint64(block.timestamp)
        });

        _safeMint(holder, tokenId);

        // Best-effort ledger event. don't revert the mint if ledger
        // is misconfigured. LOW-7: emit a tracked event so monitoring
        // can alert on drift between mints and counters.
        if (address(ledger) != address(0)) {
            try ledger.record(
                piece.mainnetCollection,
                piece.mainnetTokenId,
                ILionLedger.EventType.ArtMinted,
                bytes32(tokenId),
                bytes("")
            ) {} catch {
                emit LedgerWriteFailed(
                    tokenId, piece.mainnetCollection, piece.mainnetTokenId
                );
            }
        }

        emit PieceMinted(
            tokenId,
            piece.mainnetCollection,
            piece.mainnetTokenId,
            holder,
            piece.eventKind
        );
    }

    // --- tokenURI (on-chain) ----------------------------------------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Piece memory p = pieces[tokenId];

        ILionRenderer.RenderInputs memory inputs = ILionRenderer.RenderInputs({
            bitmap: p.bitmap,
            level: p.level,
            activitySeed: p.activitySeed,
            eventKind: p.eventKind,
            eventData: p.eventData,
            name: p.name,
            mainnetTokenId: p.mainnetTokenId
        });

        string memory imageData = renderer.renderDataURI(inputs);

        string memory json = string.concat(
            '{"name":"',
            _escapeJSON(p.name),
            unicode" \xe2\x80\x94 Lion #",
            p.mainnetTokenId.toString(),
            '","description":"',
            'Activity-anchored art for Lazy Lion #',
            p.mainnetTokenId.toString(),
            '. Minted from on-chain ledger state on Base.","image":"',
            imageData,
            '","attributes":[',
            '{"trait_type":"Mainnet Token","value":"',
            p.mainnetTokenId.toString(),
            '"},{"trait_type":"Level","value":',
            uint256(p.level).toString(),
            '},{"trait_type":"Event Kind","value":',
            uint256(p.eventKind).toString(),
            '},{"trait_type":"Minted At","value":',
            uint256(p.mintedAt).toString(),
            "}]}"
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @dev Minimal JSON string escaper for values interpolated into the
    ///      tokenURI metadata. The renderer escapes for SVG/XML; this
    ///      escapes for the surrounding JSON. Without it a name with a
    ///      double-quote or backslash produces invalid JSON.
    function _escapeJSON(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == "\\") out = abi.encodePacked(out, "\\\\");
            else if (c == '"') out = abi.encodePacked(out, "\\\"");
            else if (c == 0x08) out = abi.encodePacked(out, "\\b");
            else if (c == 0x09) out = abi.encodePacked(out, "\\t");
            else if (c == 0x0A) out = abi.encodePacked(out, "\\n");
            else if (c == 0x0C) out = abi.encodePacked(out, "\\f");
            else if (c == 0x0D) out = abi.encodePacked(out, "\\r");
            else if (uint8(c) < 0x20) continue; // drop other control chars
            else out = abi.encodePacked(out, c);
        }
        return string(out);
    }

    /// @notice EIP-712 digest helper for the LazyLionAgents site to
    ///         compute the message a holder needs to sign.
    function mintIntentDigest(
        address mainnetCollection,
        uint256 mainnetTokenId,
        address holder,
        uint8 eventKind,
        bytes32 eventData,
        bytes32 activitySeed,
        bytes32 bitmapHash,
        uint8 level,
        uint256 nonce,
        uint64 validUntil
    ) external view returns (bytes32) {
        bytes32 intentStruct = keccak256(
            abi.encode(
                MINT_INTENT_TYPEHASH,
                mainnetCollection,
                mainnetTokenId,
                holder,
                eventKind,
                eventData,
                activitySeed,
                bitmapHash,
                level,
                nonce,
                validUntil,
                address(renderer)
            )
        );
        return _hashTypedDataV4(intentStruct);
    }
}
