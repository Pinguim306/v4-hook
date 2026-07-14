// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibString} from "solady/src/utils/LibString.sol";
import {Base64} from "solady/src/utils/Base64.sol";

/// @notice one v4 pool. 4663 arrows.
/// @author Quiver — a fair launch on Robinhood Chain, in the spirit of Prism (0xsolazy).
/// @dev Fully on-chain generative art. Each token is a ballistics blueprint: a single arrow
///   loosed on a parabolic trajectory toward a target. The seed (keccak256(id, hook)) drives
///   launch angle, draw weight, range and the fletching hue — the only colour in the frame.
library QuiverArt {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           PUBLIC                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the full `data:application/json;base64,...` ERC-721 token URI.
    function tokenURI(uint256 tokenId, bytes32 seed) internal pure returns (string memory) {
        string memory svg = _renderSVG(seed);
        string memory traits = _renderTraits(seed);
        string memory json = string(
            abi.encodePacked(
                '{"name":"Arrow #',
                LibString.toString(tokenId),
                '","description":"An arrow from the Quiver v4 liquidity pool. ',
                'Each NFT is a 1/4663 share of one Uniswap v4 position on Robinhood Chain, rendered fully on-chain.",',
                '"image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '",',
                '"attributes":',
                traits,
                "}"
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @dev Raw SVG string for the given seed. Useful for off-chain preview.
    function renderSVG(bytes32 seed) internal pure returns (string memory) {
        return _renderSVG(seed);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          INTERNAL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct Ballistics {
        uint16 hue; // 0..359   — fletching colour
        uint16 angle; // 25..65   — launch angle in degrees
        uint16 draw; // 30..70   — draw weight in lb
        uint16 rangeM; // 40..199  — range in metres
        uint16 apexY; // derived  — trajectory apex (screen y)
        uint16 landX; // derived  — landing / target x
        int256 ctrlY; // derived  — quadratic control-point y (may sit above the frame, < 0)
        uint8 accent; // annotation toggles
    }

    /// @dev Ground baseline and launch origin are fixed; everything else derives from the seed.
    uint16 internal constant GROUND_Y = 300;
    uint16 internal constant LAUNCH_X = 70;

    function _ballistics(bytes32 seed) private pure returns (Ballistics memory b) {
        b.hue = uint16(uint256(uint8(seed[0])) * 360 / 256); // 0..359
        b.angle = 25 + uint16(uint8(seed[1])) % 41; // 25..65
        b.draw = 30 + uint16(uint8(seed[2])) % 41; // 30..70
        b.rangeM = 40 + uint16(uint8(seed[3])) % 160; // 40..199
        b.accent = uint8(seed[4]);

        // Higher launch angle → higher apex (smaller screen y). 25°→210, 65°→130.
        b.apexY = 210 - (b.angle - 25) * 2;
        // Landing x drifts right with a byte of entropy so no two frames land alike.
        b.landX = 300 + uint16(uint8(seed[5])) % 60; // 300..359
        // Quadratic control-point y so the curve peak sits exactly at apexY.
        // For a high apex this lands above the top edge (negative), which is valid SVG.
        b.ctrlY = 2 * int256(uint256(b.apexY)) - int256(uint256(GROUND_Y));
    }

    function _renderSVG(bytes32 seed) private pure returns (string memory) {
        Ballistics memory b = _ballistics(seed);
        uint16 apexX = (LAUNCH_X + b.landX) / 2;
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" style="background:#000">',
                _grid(),
                _cornerMarks(),
                _ground(),
                _bow(),
                _trajectory(b, apexX),
                _arrow(b.hue, apexX, b.apexY),
                _target(b.landX),
                _launchAnnotations(b.accent),
                _titleBlock(seed, b),
                "</svg>"
            )
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ELEMENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Faint background grid, 50px spacing.
    function _grid() private pure returns (string memory) {
        return '<g stroke="#fff" stroke-width="0.5" opacity="0.05">' '<line x1="0" y1="50" x2="400" y2="50"/>'
            '<line x1="0" y1="100" x2="400" y2="100"/>' '<line x1="0" y1="150" x2="400" y2="150"/>'
            '<line x1="0" y1="200" x2="400" y2="200"/>' '<line x1="0" y1="250" x2="400" y2="250"/>'
            '<line x1="0" y1="300" x2="400" y2="300"/>' '<line x1="0" y1="350" x2="400" y2="350"/>'
            '<line x1="50" y1="0" x2="50" y2="400"/>' '<line x1="100" y1="0" x2="100" y2="400"/>'
            '<line x1="150" y1="0" x2="150" y2="400"/>' '<line x1="200" y1="0" x2="200" y2="400"/>'
            '<line x1="250" y1="0" x2="250" y2="400"/>' '<line x1="300" y1="0" x2="300" y2="400"/>'
            '<line x1="350" y1="0" x2="350" y2="400"/>' "</g>";
    }

    /// @dev Viewport crop marks at the four corners.
    function _cornerMarks() private pure returns (string memory) {
        return '<g stroke="#fff" stroke-width="1" fill="none" opacity="0.45">'
            '<path d="M10,30 L10,10 L30,10"/>' '<path d="M370,10 L390,10 L390,30"/>'
            '<path d="M390,370 L390,390 L370,390"/>' '<path d="M30,390 L10,390 L10,370"/>' "</g>";
    }

    /// @dev Ground baseline with measurement ticks.
    function _ground() private pure returns (string memory) {
        return '<line x1="20" y1="300" x2="380" y2="300" stroke="#fff" stroke-width="1" opacity="0.6"/>'
            '<g stroke="#fff" stroke-width="0.5" opacity="0.5">' '<line x1="110" y1="300" x2="110" y2="307"/>'
            '<line x1="160" y1="300" x2="160" y2="307"/>' '<line x1="210" y1="300" x2="210" y2="307"/>'
            '<line x1="260" y1="300" x2="260" y2="307"/>' '<line x1="310" y1="300" x2="310" y2="307"/>' "</g>";
    }

    /// @dev The bow at the launch origin: a vertical arc with its string.
    function _bow() private pure returns (string memory) {
        return '<path d="M70,255 Q95,300 70,345" fill="none" stroke="#fff" stroke-width="1.5"/>'
            '<line x1="70" y1="255" x2="70" y2="345" stroke="#fff" stroke-width="0.7" opacity="0.7"/>'
            '<circle cx="70" cy="300" r="2" fill="#fff"/>';
    }

    /// @dev Dashed parabolic trajectory from bow to target apexed at the seed's height.
    function _trajectory(Ballistics memory b, uint16 apexX) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<path d="M',
                LibString.toString(uint256(LAUNCH_X)),
                ",",
                LibString.toString(uint256(GROUND_Y)),
                " Q",
                LibString.toString(uint256(apexX)),
                ",",
                LibString.toString(b.ctrlY),
                " ",
                LibString.toString(uint256(b.landX)),
                ",",
                LibString.toString(uint256(GROUND_Y)),
                '" fill="none" stroke="#fff" stroke-width="1" stroke-dasharray="3,3" opacity="0.55"/>'
            )
        );
    }

    /// @dev The arrow itself, riding the apex. Shaft/head white; fletching in the seed hue —
    ///   the single colour element in the whole composition.
    function _arrow(uint16 hue, uint16 apexX, uint16 apexY) private pure returns (string memory) {
        string memory hs = string(abi.encodePacked("hsl(", LibString.toString(uint256(hue)), ",82%,62%)"));
        return string(
            abi.encodePacked(
                '<g transform="translate(',
                LibString.toString(uint256(apexX)),
                ",",
                LibString.toString(uint256(apexY)),
                ')">',
                // shaft
                '<line x1="-16" y1="0" x2="14" y2="0" stroke="#fff" stroke-width="1.5"/>',
                // arrowhead
                '<polygon points="14,-4 22,0 14,4" fill="#fff"/>',
                // fletching (colour)
                '<path d="M-16,0 L-22,-5 M-16,0 L-22,5 M-12,0 L-18,-5 M-12,0 L-18,5" stroke="',
                hs,
                '" stroke-width="1.5" fill="none"/>',
                "</g>"
            )
        );
    }

    /// @dev Concentric-ring target planted at the landing point.
    function _target(uint16 landX) private pure returns (string memory) {
        string memory x = LibString.toString(uint256(landX));
        return string(
            abi.encodePacked(
                '<g fill="none" stroke="#fff" opacity="0.7">',
                '<line x1="',
                x,
                '" y1="300" x2="',
                x,
                '" y2="255" stroke-width="0.7"/>',
                '<circle cx="',
                x,
                '" cy="252" r="12" stroke-width="1"/>',
                '<circle cx="',
                x,
                '" cy="252" r="7" stroke-width="0.8"/>',
                '<circle cx="',
                x,
                '" cy="252" r="2" fill="#fff" stroke="none"/>',
                "</g>"
            )
        );
    }

    /// @dev Launch-angle arc at the origin plus optional annotations toggled by `accent` bits.
    function _launchAnnotations(uint8 accent) private pure returns (string memory) {
        bytes memory s = abi.encodePacked(
            // reference horizontal + angle arc at the bow (70,300)
            '<g stroke="#fff" stroke-width="0.6" opacity="0.7" fill="none">',
            '<line x1="70" y1="300" x2="120" y2="300" stroke-dasharray="1,2"/>',
            '<path d="M 110,300 A 40,40 0 0,0 96,272" stroke-dasharray="1,2"/>',
            "</g>"
        );
        // bit 0: apex crosshair marker
        if (accent & 0x01 != 0) {
            s = abi.encodePacked(
                s,
                '<g stroke="#fff" stroke-width="0.5" opacity="0.5"><line x1="200" y1="150" x2="200" y2="140"/>'
                '<line x1="195" y1="145" x2="205" y2="145"/></g>'
            );
        }
        // bit 1: wind vector at top-right
        if (accent & 0x02 != 0) {
            s = abi.encodePacked(
                s,
                '<g stroke="#fff" stroke-width="0.6" opacity="0.55"><line x1="330" y1="60" x2="360" y2="60"/>'
                '<path d="M354,55 L360,60 L354,65" fill="none"/></g>'
            );
        }
        // bit 2: range extension tick past the target
        if (accent & 0x04 != 0) {
            s = abi.encodePacked(
                s,
                '<circle cx="120" cy="252" r="1.5" fill="none" stroke="#fff" stroke-width="0.5" opacity="0.6"/>'
            );
        }
        return string(s);
    }

    /// @dev Monospaced title block at the bottom: brand // seed digest, angle, draw, range.
    function _titleBlock(bytes32 seed, Ballistics memory b) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="9" fill="#fff" opacity="0.55">',
                '<text x="20" y="375">QUIVER // ',
                _digest(seed),
                "</text>",
                '<text x="380" y="375" text-anchor="end">',
                "&#952;=",
                LibString.toString(uint256(b.angle)),
                "&#176;   ",
                LibString.toString(uint256(b.draw)),
                "lb   ",
                LibString.toString(uint256(b.rangeM)),
                "m</text>",
                "</g>"
            )
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          FORMAT                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev "0xAABBCC" hex digest from the first 3 seed bytes.
    function _digest(bytes32 seed) private pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory out = new bytes(8);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 3; i++) {
            uint8 bb = uint8(seed[i]);
            out[2 + i * 2] = hexChars[bb >> 4];
            out[2 + i * 2 + 1] = hexChars[bb & 0x0f];
        }
        return string(out);
    }

    function _renderTraits(bytes32 seed) private pure returns (string memory) {
        Ballistics memory b = _ballistics(seed);
        return string(
            abi.encodePacked(
                "[",
                '{"trait_type":"Launch Angle","value":',
                LibString.toString(uint256(b.angle)),
                "},",
                '{"trait_type":"Draw Weight","value":"',
                LibString.toString(uint256(b.draw)),
                'lb"},',
                '{"trait_type":"Range","value":"',
                LibString.toString(uint256(b.rangeM)),
                'm"},',
                '{"trait_type":"Fletching Hue","value":',
                LibString.toString(uint256(b.hue)),
                "}",
                "]"
            )
        );
    }
}
