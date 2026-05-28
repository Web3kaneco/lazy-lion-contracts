// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LionRenderer} from "../src/LionRenderer.sol";
import {ILionRenderer} from "../src/interfaces/ILionRenderer.sol";

contract LionRendererTest is Test {
    LionRenderer renderer;

    function setUp() public {
        renderer = new LionRenderer();
    }

    function _inputs() internal pure returns (ILionRenderer.RenderInputs memory) {
        bytes memory bitmap = new bytes(200);
        // sparse bitmap — just a few pixels set so the SVG isn't gigantic
        bitmap[0] = 0xFF;
        bitmap[10] = 0xAA;
        bitmap[100] = 0x55;
        return ILionRenderer.RenderInputs({
            bitmap: bitmap,
            level: 3,
            activitySeed: keccak256("seed"),
            eventKind: 1, // EVOLVE
            eventData: bytes32(0),
            name: "Stripes",
            mainnetTokenId: 4599
        });
    }

    function test_render_produces_svg() public view {
        string memory svg = renderer.renderSVG(_inputs());
        bytes memory b = bytes(svg);
        assertGt(b.length, 100);
        // Must start with <svg
        assertEq(b[0], "<");
        assertEq(b[1], "s");
        assertEq(b[2], "v");
        assertEq(b[3], "g");
    }

    function test_render_data_uri_format() public view {
        string memory uri = renderer.renderDataURI(_inputs());
        bytes memory b = bytes(uri);
        // Must start with "data:image/svg+xml;base64,"
        assertGt(b.length, 26);
        assertEq(b[0], "d");
        assertEq(b[5], "i");
    }

    function test_render_escapes_special_chars_in_name() public view {
        ILionRenderer.RenderInputs memory inp = _inputs();
        inp.name = "<bad>&'name";
        string memory svg = renderer.renderSVG(inp);
        // Verify the raw chars don't appear as text in the SVG body
        bytes memory b = bytes(svg);
        // Search for unescaped "<bad>" — should not be present
        bool foundBad = false;
        for (uint256 i = 0; i + 4 < b.length; i++) {
            if (b[i] == "<" && b[i+1] == "b" && b[i+2] == "a" && b[i+3] == "d" && b[i+4] == ">") {
                foundBad = true;
                break;
            }
        }
        assertFalse(foundBad);
    }
}
