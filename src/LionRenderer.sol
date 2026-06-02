// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ILionRenderer} from "./interfaces/ILionRenderer.sol";

/// @title LionRenderer
/// @notice Pure-Solidity SVG renderer for Lion art pieces.
///
/// @dev v1 algorithm. Produces a 480x480 SVG with four layers:
///   1. Gold background colored by activity seed
///   2. Generative pixel field whose density scales with level
///   3. The Lion's bitmap rendered as 40x40 pixels in the center
///   4. A frame with name + token id + event type
///
/// Designed to be replaced or extended later. Other contracts depend
/// only on the interface, not on the algorithm details. A future
/// LionRenderer v2 can ship as a separate deployment and the metadata
/// pointer can switch over to it.
contract LionRenderer is ILionRenderer {
    using Strings for uint256;

    uint256 internal constant CANVAS = 480;
    uint256 internal constant BITMAP_SIZE = 40;
    uint256 internal constant PIXEL_SIZE = 6; // 40 * 6 = 240, centered
    uint256 internal constant BITMAP_OFFSET = (CANVAS - BITMAP_SIZE * PIXEL_SIZE) / 2;
    /// @dev Hard cap on background pixel count to keep SVG size bounded
    ///      regardless of level (LOW-5).
    uint256 internal constant MAX_BG_PIXELS = 400;
    /// @dev Expected bitmap byte length (40*40 / 8) (LOW-6).
    uint256 internal constant EXPECTED_BITMAP_LEN = 200;

    error InvalidBitmapLength(uint256 got, uint256 expected);

    /// @dev Event kind labels (short, for the frame). A pure function
    ///      rather than a storage array so the render path stays `pure`
    ///      (Solidity has no constant string[] type).
    function _eventLabel(uint256 ev) internal pure returns (string memory) {
        if (ev == 0) return "ANCHOR"; // generic anchor mint
        if (ev == 1) return "EVOLVE"; // level milestone
        if (ev == 2) return "VERDICT"; // swarm verdict
        if (ev == 3) return "SUB"; // subscription anniversary
        if (ev == 4) return "STREAK"; // pick streak
        if (ev == 5) return "TOOL"; // tool authorization
        if (ev == 6) return "LORE"; // lore update
        return "CUSTOM"; // 7+ anything else
    }

    /// @inheritdoc ILionRenderer
    function renderSVG(RenderInputs calldata inputs)
        external
        pure
        returns (string memory)
    {
        return _render(inputs);
    }

    /// @inheritdoc ILionRenderer
    function renderDataURI(RenderInputs calldata inputs)
        external
        pure
        returns (string memory)
    {
        string memory svg = _render(inputs);
        return string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );
    }

    // --- Internal ----------------------------------------------------

    function _render(RenderInputs memory inputs) internal pure returns (string memory) {
        if (inputs.bitmap.length != EXPECTED_BITMAP_LEN) {
            revert InvalidBitmapLength(inputs.bitmap.length, EXPECTED_BITMAP_LEN);
        }
        // Derive palette + density from activity seed + level
        (string memory bg, string memory accent) = _palette(inputs.activitySeed);
        uint256 density = 40 + uint256(inputs.level) * 20;
        if (density > MAX_BG_PIXELS) density = MAX_BG_PIXELS;

        string memory bgRect = string.concat(
            '<rect width="100%" height="100%" fill="',
            bg,
            '"/>'
        );

        string memory bgPixels = _renderBackgroundPixels(
            inputs.activitySeed, density, accent
        );

        string memory lion = _renderBitmap(inputs.bitmap, accent);

        string memory frame = _renderFrame(inputs, accent);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480" ',
            'shape-rendering="crispEdges">',
            bgRect,
            bgPixels,
            lion,
            frame,
            "</svg>"
        );
    }

    /// @dev Picks two gold-family colors from the seed. Keeps the
    ///      Lions visual identity while allowing variance.
    function _palette(bytes32 seed)
        internal
        pure
        returns (string memory bg, string memory accent)
    {
        uint8 v = uint8(seed[0]);
        if (v < 64) {
            bg = "#1a1408";
            accent = "#d4a017"; // deep gold
        } else if (v < 128) {
            bg = "#0a0a0a";
            accent = "#e8b800"; // bright gold
        } else if (v < 192) {
            bg = "#1f1a05";
            accent = "#c19b2e"; // muted gold
        } else {
            bg = "#000000";
            accent = "#ffd700"; // pure gold
        }
    }

    /// @dev Sprinkle accent-colored pixels across the canvas with a
    ///      density driven by level. Deterministic from the seed.
    function _renderBackgroundPixels(
        bytes32 seed,
        uint256 density,
        string memory accent
    ) internal pure returns (string memory) {
        bytes memory out;
        uint256 s = uint256(seed);
        for (uint256 i = 0; i < density; i++) {
            s = uint256(keccak256(abi.encode(s, i)));
            uint256 x = (s % (CANVAS / 8)) * 8;
            uint256 y = ((s >> 8) % (CANVAS / 8)) * 8;
            uint256 size = ((s >> 16) % 3) + 2;
            out = abi.encodePacked(
                out,
                '<rect x="', x.toString(),
                '" y="', y.toString(),
                '" width="', size.toString(),
                '" height="', size.toString(),
                '" fill="', accent,
                '" opacity="0.4"/>'
            );
        }
        return string(out);
    }

    /// @dev Render the Lion's 40x40 bitmap. Each set bit becomes a
    ///      square in the accent color. The bitmap is 200 bytes
    ///      (40*40 = 1600 bits / 8).
    function _renderBitmap(bytes memory bitmap, string memory accent)
        internal
        pure
        returns (string memory)
    {
        bytes memory out;
        uint256 len = bitmap.length;
        for (uint256 i = 0; i < 1600 && (i / 8) < len; i++) {
            uint8 byteVal = uint8(bitmap[i / 8]);
            bool isOn = (byteVal & (uint8(1) << uint8(7 - (i % 8)))) != 0;
            if (!isOn) continue;
            uint256 x = (i % BITMAP_SIZE) * PIXEL_SIZE + BITMAP_OFFSET;
            uint256 y = (i / BITMAP_SIZE) * PIXEL_SIZE + BITMAP_OFFSET;
            out = abi.encodePacked(
                out,
                '<rect x="', x.toString(),
                '" y="', y.toString(),
                '" width="', PIXEL_SIZE.toString(),
                '" height="', PIXEL_SIZE.toString(),
                '" fill="', accent,
                '"/>'
            );
        }
        return string(out);
    }

    function _renderFrame(RenderInputs memory inputs, string memory accent)
        internal
        pure
        returns (string memory)
    {
        uint256 ev = inputs.eventKind < 8 ? inputs.eventKind : 7;
        string memory label = _eventLabel(ev);
        string memory border = string.concat(
            '<rect x="4" y="4" width="472" height="472" fill="none" stroke="',
            accent,
            '" stroke-width="2"/>'
        );
        string memory topText = string.concat(
            '<text x="20" y="28" font-family="monospace" font-size="14" fill="',
            accent,
            '">',
            _escape(inputs.name),
            "</text>"
        );
        string memory bottomText = string.concat(
            '<text x="20" y="464" font-family="monospace" font-size="12" fill="',
            accent,
            '">#',
            inputs.mainnetTokenId.toString(),
            unicode" \xc2\xb7 LVL ",
            uint256(inputs.level).toString(),
            unicode" \xc2\xb7 ",
            label,
            "</text>"
        );
        return string.concat(border, topText, bottomText);
    }

    /// @dev SVG/XML-safe escape. Handles XML special chars and strips
    ///      control bytes (0x00-0x1F except tab/newline/cr) which would
    ///      break SVG parsers. Multibyte UTF-8 sequences pass through
    ///      unchanged (each byte ≥ 0x80 is preserved verbatim).
    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            uint8 v = uint8(c);
            // Strip dangerous control characters (keep \t \n \r)
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) continue;
            if (v == 0x7F) continue; // DEL
            if (c == "&") out = abi.encodePacked(out, "&amp;");
            else if (c == "<") out = abi.encodePacked(out, "&lt;");
            else if (c == ">") out = abi.encodePacked(out, "&gt;");
            else if (c == '"') out = abi.encodePacked(out, "&quot;");
            else if (c == "'") out = abi.encodePacked(out, "&#39;");
            else out = abi.encodePacked(out, c);
        }
        return string(out);
    }
}
