// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/**
 * This interf
 */
interface IERC721 {
    function setApprovalForAll(address operator, bool approved) external;

    function approve(address _to, uint256 _tokenId) external;
}
