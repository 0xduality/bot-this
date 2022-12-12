// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/tokens/BotThis.sol";
import "../src/tokens/IBotThisErrors.sol";
import "@solbase/utils/LibString.sol";

/*

  "cancelAuction()": "8fa8b790",
  "collectionSize()": "45c0f533",
  "commitBid(bytes21)": "3bbd3c2f",
  "createAuction(uint32,uint32,uint32,uint88)": "d4e2590f",
  "currentTokenId()": "009a9b7b",
  "emergencyReveal()": "1bb6716a",
  "finalizeAuction()": "f77282ab",
  "getApproved(uint256)": "081812fc",
  "isApprovedForAll(address,address)": "e985e9c5",
  "mint()": "1249c58b",
  "name()": "06fdde03",
  "outcomes(address)": "927f1833",
  "owner()": "8da5cb5b",
  "ownerOf(uint256)": "6352211e",
  "revealBid(uint8,uint88,bytes32)": "c4bfdcf1",
  "revealedBids(uint256)": "ae05377d",
  "safeTransferFrom(address,address,uint256)": "42842e0e",
  "safeTransferFrom(address,address,uint256,bytes)": "b88d4fde",
  "sealedBids(address)": "1402ac15",
  "setApprovalForAll(address,bool)": "a22cb465",
  "setURI(string)": "02fe5305",
  "supportsInterface(bytes4)": "01ffc9a7",
  "symbol()": "95d89b41",
  "tokenURI(uint256)": "c87b56dd",
  "topBidders()": "b3bedadc",
  "transferFrom(address,address,uint256)": "23b872dd",
  "transferOwnership(address)": "f2fde38b",
  "withdrawBalance()": "5fd8c710",
  "withdrawCollateral()": "59c153be",
  "withdrawableBalance()": "e62d64f6"

  "approve(address,uint256)": "095ea7b3",
  "auction()": "7d9f6db5",
  "balanceOf(address)": "70a08231",
  "baseURI()": "6c0360eb",
*/

contract BotThisTest is Test,  IBotThisErrors {
    using stdStorage for StdStorage;
    using LibString for uint256;

    address[] public bidders;
    address deployer;
    BotThis public nft;
    BotThis public nft10;
    BotThis public nft12;
    BotThis public nft14;

    function commitBid(address from, BotThis to, uint256 collateral, bytes32 nonce, uint88 bidValue, uint8 bidAmount) private returns (bytes21 commitment)
    {
        commitment = bytes21(keccak256(abi.encode(nonce, bidValue, bidAmount, address(to))));
        vm.prank(from);
        to.commitBid{value: collateral}(commitment);
        return commitment;
    }

    function revealBid(address from, BotThis to, bytes32 nonce, uint88 bidValue, uint8 bidAmount) private
    {
        vm.prank(from);
        to.revealBid(nonce, bidValue, bidAmount);
    }

    function mint(address from, BotThis to) private
    {
        vm.prank(from);
        to.mint();
    }

    function withdrawCollateral(address from, BotThis to) private
    {
        vm.prank(from);
        to.withdrawCollateral();
    }

    function setUp() public {
        deployer = tx.origin;
        for (uint256 i=0; i<12; ++i){
            string memory bidderName = string(abi.encodePacked("bidder", i.toString()));
            address bidderAddy = address(uint160(uint256(keccak256(bytes(bidderName))))); 
            bidders.push(bidderAddy);
            vm.label(bidderAddy, bidderName);
            vm.deal(bidderAddy, 10 ether);
            //console.log(bidderName, bidderAddy, bidderAddy.balance);
        }
        nft = new BotThis("BotThis", "BT", 2, 4);
        nft10 = new BotThis("BotThis", "BT", 3, 10);
        nft12 = new BotThis("BotThis", "BT", 3, 12);
        nft14 = new BotThis("BotThis", "BT", 3, 14);
    }

    function testHappyScenario() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint88[] memory bidValue = new uint88[](3);
        uint8[] memory bidAmount = new uint8[](3);
        collateral[0] = 7 ether; collateral[1] = 6 ether; collateral[2] = 4 ether; 
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        bidValue[0] = 6 ether; bidValue[1] = 5 ether; bidValue[2] = 2 ether; 
        bidAmount[0] = 2; bidAmount[1] = 1; bidAmount[2] = 1; 

        uint88 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();
        mint(bidders[1], nft);
        require(nft.balanceOf(bidders[1])==bidAmount[1]);
        mint(bidders[2], nft);
        require(nft.balanceOf(bidders[2])==bidAmount[2]);
        for (uint i=0; i<3; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - prevBalance == 5 ether);
        require(bidders[0].balance == 10 ether);
        require(bidders[1].balance == 6 ether);
        require(bidders[2].balance == 9 ether);
    }
}
