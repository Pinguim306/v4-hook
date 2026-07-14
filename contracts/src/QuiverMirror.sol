// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IQuiverHookNFT {
    function nftOwnerOf(uint256 tokenId) external view returns (address);
    function nftBalanceOf(address owner) external view returns (uint256);
    function nftTokenURI(uint256 tokenId) external view returns (string memory);
    function nftGetApproved(uint256 tokenId) external view returns (address);
    function nftIsApprovedForAll(address owner, address operator) external view returns (bool);

    function handleNFTTransfer(address from, address to, uint256 tokenId, address caller) external;
    function handleNFTApprove(address spender, uint256 tokenId, address caller) external;
    function handleNFTSetApprovalForAll(address operator, bool approved, address caller) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @notice one v4 pool. 4663 arrows.
/// @author Quiver — a fair launch on Robinhood Chain, in the spirit of Prism (0xsolazy).
/// @dev ERC-721 facade. Holds no state of its own: every read and write delegates to the
///   hook, which owns the packed NFT ledger and calls back here to emit the canonical
///   ERC-721 events (that is what marketplaces and indexers watch).
contract QuiverMirror {
    error OnlyHook();
    error NonERC721Receiver();

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    string public constant name = "Quiver-LP";
    string public constant symbol = "QUIVER-LP";
    address public immutable hook;

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address _hook) {
        hook = _hook;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return IQuiverHookNFT(hook).nftOwnerOf(tokenId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return IQuiverHookNFT(hook).nftBalanceOf(owner);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        return IQuiverHookNFT(hook).nftTokenURI(tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return IQuiverHookNFT(hook).nftGetApproved(tokenId);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return IQuiverHookNFT(hook).nftIsApprovedForAll(owner, operator);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f;
    }

    function approve(address to, uint256 tokenId) external {
        IQuiverHookNFT(hook).handleNFTApprove(to, tokenId, msg.sender);
    }

    function setApprovalForAll(address operator, bool approved) external {
        IQuiverHookNFT(hook).handleNFTSetApprovalForAll(operator, approved, msg.sender);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        IQuiverHookNFT(hook).handleNFTTransfer(from, to, tokenId, msg.sender);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert NonERC721Receiver();
            } catch {
                revert NonERC721Receiver();
            }
        }
    }

    function emitTransfer(address from, address to, uint256 tokenId) external onlyHook {
        emit Transfer(from, to, tokenId);
    }

    function emitApproval(address owner, address approved, uint256 tokenId) external onlyHook {
        emit Approval(owner, approved, tokenId);
    }

    function emitApprovalForAll(address owner, address operator, bool approved) external onlyHook {
        emit ApprovalForAll(owner, operator, approved);
    }
}
