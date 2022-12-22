// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/tokens/BotThis.sol";
import "../src/tokens/IBotThisErrors.sol";
import "@solbase/utils/LibString.sol";
import {Owned} from "@solbase/auth/Owned.sol";

contract BotThisTest is Test,  IBotThisErrors {
    using stdStorage for StdStorage;
    using LibString for uint256;

    address[] public bidders;
    address deployer;
    BotThis public nft;
    BotThis public nftbig;

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
        for (uint256 i=0; i<10; ++i){
            string memory bidderName = string(abi.encodePacked("bidder", i.toString()));
            address bidderAddy = address(uint160(uint256(keccak256(bytes(bidderName))))); 
            bidders.push(bidderAddy);
            vm.label(bidderAddy, bidderName);
            vm.deal(bidderAddy, 10 ether);
            //console.log(bidderName, bidderAddy, bidderAddy.balance);
        }
        nft = new BotThis("BotThis", "BT", 2, 3);
        nftbig = new BotThis("BotThis2", "BT2", 50, 255);
    }

    function testHappyCase() public {
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
        vm.prank(deployer);
        nft.setURI("ipfs://hash/");
        console.log(nft.tokenURI(0));
        vm.prank(bidders[1]);
        nft.approve(bidders[0],0);
        vm.prank(bidders[2]);
        nft.setApprovalForAll(bidders[0], true);
        vm.prank(bidders[0]);
        nft.safeTransferFrom(bidders[1],bidders[0], 0);
        vm.prank(bidders[0]);
        nft.safeTransferFrom(bidders[2],bidders[0], 1);
        require(nft.balanceOf(bidders[0])==2);
        require(nft.balanceOf(bidders[1])==0);
        require(nft.balanceOf(bidders[2])==0);
    }

    function testOnlyOwnerCreateAuction() public {
        uint88 reservePrice = 1 ether;
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
    }

    function testCreateAuctionMisconfiguration() public {
        uint88 reservePrice = 1 ether;
        skip(2 minutes);
        vm.prank(deployer);        
        vm.expectRevert(BidPeriodTooShortError.selector);
        nft.createAuction(uint32(block.timestamp), 2 minutes, 2 hours, reservePrice);
        vm.prank(deployer);        
        vm.expectRevert(RevealPeriodTooShortError.selector);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 minutes, reservePrice);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartTimeError.selector);
        nft.createAuction(1, 2 hours, 2 hours, reservePrice);
        vm.prank(deployer);
        nft.createAuction(0, 2 hours, 2 hours, reservePrice);
    }

    function testCanOnlyMoveAuctionBackAndBeforeStart() public {
        uint88 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp + 2 hours), 2 hours, 2 hours, reservePrice);
        skip(30 minutes);
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp + 2 hours), 2 hours, 2 hours, reservePrice);
        skip(30 minutes);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartTimeError.selector);
        nft.createAuction(uint32(block.timestamp + 30 minutes), 2 hours, 2 hours, reservePrice);
        skip(3 hours);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartTimeError.selector);
        nft.createAuction(uint32(block.timestamp + 2 hours), 2 hours, 2 hours, reservePrice);
    }

    function testBadCommits() public {
        uint88 reservePrice = 1 ether;

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp + 30 minutes), 2 hours, 2 hours, reservePrice);
        skip(20 minutes);
        vm.prank(bidders[0]);
        vm.expectRevert(NotInBidPeriodError.selector);
        nft.commitBid{value: 2 ether}(bytes21("commitment"));
        skip(20 minutes);
        vm.prank(bidders[0]);
        vm.expectRevert(ZeroCommitmentError.selector);
        nft.commitBid{value: 2 ether}(bytes21(0));
        vm.prank(bidders[0]);
        vm.expectRevert(CollateralLessThanReservePriceError.selector);
        nft.commitBid{value: 0 ether}(bytes21("commitment"));
        skip(5 hours);
        vm.prank(bidders[0]);
        vm.expectRevert(NotInBidPeriodError.selector);
        nft.commitBid{value: 2 ether}(bytes21("commitment"));
    }

    function testBadReveals() public {

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
        skip(2 minutes);
        vm.expectRevert(NotInRevealPeriodError.selector);
        revealBid(bidders[0], nft, nonce[0], bidValue[0], bidAmount[0]);
        skip(2 hours);
        (bytes21 commitment,) = nft.sealedBids(bidders[0]);
        bytes21 badNonceCommitment = bytes21(keccak256(abi.encode(nonce[1], bidValue[0], bidAmount[0], address(nft))));
        vm.expectRevert(abi.encodeWithSelector(InvalidOpeningError.selector, badNonceCommitment, commitment));
        revealBid(bidders[0], nft, nonce[1], bidValue[0], bidAmount[0]);
        revealBid(bidders[0], nft, nonce[0], bidValue[0], bidAmount[0]);
        skip(5 hours);
        vm.expectRevert(NotInRevealPeriodError.selector);
        revealBid(bidders[1], nft, nonce[1], bidValue[1], bidAmount[1]);
    }

    function testSneakyBids() public {

        uint88 reservePrice = 3 ether;

        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint88[] memory bidValue = new uint88[](3);
        uint8[] memory bidAmount = new uint8[](3);
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        collateral[0] = 6 ether; collateral[1] = 4 ether; collateral[2] = 5 ether; 
        bidValue[0] = 7 ether; bidValue[1] = 2 ether; bidValue[2] = 4 ether; 
        bidAmount[0] = 2; bidAmount[1] = 1; bidAmount[2] = 255; 

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for(uint i=0; i<3; ++i){
            require(bidders[i].balance == 10 ether, "Precondition not met");
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
            require(bidders[i].balance < 10 ether, "Collateral not posted");
        }
        skip(2 hours);
        for(uint i=0; i<3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
            require(bidders[i].balance == 10 ether, "Sneaky bidder not refunded");
        }
    }

    function testEmergencyReveal() public {
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
        vm.prank(bidders[0]);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        nft.emergencyReveal();
        skip(2 hours);
        for(uint i=1; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        vm.prank(bidders[0]);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        nft.emergencyReveal();
        skip(2 hours);
        vm.prank(bidders[0]);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        nft.emergencyReveal();
        vm.prank(deployer);
        nft.finalizeAuction();
        vm.prank(bidders[0]);
        nft.emergencyReveal();
        for (uint i=0; i<3; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
        }
        require(bidders[0].balance == 10 ether, "emergencyReveal did not work");
    }

    function testWithdrawCollateral() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint88[] memory bidValue = new uint88[](3);
        uint8[] memory bidAmount = new uint8[](3);
        collateral[0] = 7 ether; collateral[1] = 6 ether; collateral[2] = 4 ether; 
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        bidValue[0] = 6 ether; bidValue[1] = 5 ether; bidValue[2] = 2 ether; 
        bidAmount[0] = 2; bidAmount[1] = 1; bidAmount[2] = 1; 

        uint88 reservePrice = 1 ether;

        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        vm.expectRevert(UnrevealedBidError.selector);
        withdrawCollateral(bidders[0], nft);
        skip(2 hours);
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        vm.prank(deployer);
        nft.finalizeAuction();

        for (uint i=0; i<3; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
            withdrawCollateral(bidders[i], nft);
        }
    }

    function testCancelAuction() public {
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
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.cancelAuction();
        vm.prank(deployer);
        nft.cancelAuction();
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        for (uint i=0; i<3; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
            require(bidders[i].balance == 10 ether, "bidder not refunded");
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance == prevBalance, "deployer should not make money");
    }

    function testFinalizeAuction() public {
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
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.finalizeAuction();        
        vm.prank(deployer);
        nft.finalizeAuction();
        mint(bidders[1], nft);
        mint(bidders[2], nft);
        for (uint i=0; i<3; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
        }
        //uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
    }

    function testMint() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint88[] memory bidValue = new uint88[](3);
        uint8[] memory bidAmount = new uint8[](3);
        collateral[0] = 7 ether; collateral[1] = 6 ether; collateral[2] = 4 ether; 
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        bidValue[0] = 6 ether; bidValue[1] = 5 ether; bidValue[2] = 2 ether; 
        bidAmount[0] = 2; bidAmount[1] = 1; bidAmount[2] = 1; 

        uint88 reservePrice = 1 ether;
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        skip(2 minutes);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        vm.prank(deployer);
        nft.finalizeAuction();
        for (uint i=0; i<2; ++i){
            mint(bidders[0], nft);
            require(nft.balanceOf(bidders[0])==0);
            mint(bidders[1], nft);
            require(nft.balanceOf(bidders[1])==bidAmount[1]);
            mint(bidders[2], nft);
            require(nft.balanceOf(bidders[2])==bidAmount[2]);
        }
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

    function testWithdrawBalance() public {
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
        nft.withdrawBalance();

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 minutes);
        for(uint i=0; i<3; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 hours);
        for(uint i=0; i<3; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 hours);
        vm.prank(deployer);
        nft.withdrawBalance();

        vm.prank(deployer);
        nft.finalizeAuction();

        uint256 prevBalance = deployer.balance;
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.withdrawBalance();
        vm.prank(deployer);
        nft.withdrawBalance();
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - prevBalance == 5 ether);
    
        mint(bidders[1], nft);
        require(nft.balanceOf(bidders[1])==bidAmount[1]);
        mint(bidders[2], nft);
        require(nft.balanceOf(bidders[2])==bidAmount[2]);
    }

    function testOverCapacity() public {
        uint256[] memory collateral = new uint256[](6);
        bytes32[] memory nonce = new bytes32[](6);
        uint88[] memory bidValue = new uint88[](6);
        uint8[] memory bidAmount = new uint8[](6);
        collateral[0] = 7 ether; collateral[1] = 6 ether; collateral[2] = 4 ether; 
        collateral[3] = 7 ether; collateral[4] = 6 ether; collateral[5] = 4 ether; 
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        nonce[3] = bytes32("foo"); nonce[4] = bytes32("bar"); nonce[5] = bytes32("baz");
        bidValue[0] = 3 ether; bidValue[1] = 3 ether; bidValue[2] = 3 ether;
        bidValue[3] = 6 ether; bidValue[4] = 5 ether; bidValue[5] = 2 ether;         
        bidAmount[0] = 2; bidAmount[1] = 2; bidAmount[2] = 2; 
        bidAmount[3] = 2; bidAmount[4] = 1; bidAmount[5] = 1; 

        uint88 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for(uint i=0; i<6; ++i)
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        for(uint i=0; i<6; ++i)
            revealBid(bidders[i], nft, nonce[i], bidValue[i], bidAmount[i]);
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();
        for(uint i=0; i<6; ++i){
            //(uint88 payment, uint8 amount) = nft.outcomes(bidders[i]);
            mint(bidders[i], nft);
        }
        for(uint i=0; i<4; ++i)
            require(nft.balanceOf(bidders[i])==0);
        for(uint i=4; i<6; ++i)
            require(nft.balanceOf(bidders[i])==bidAmount[i]);
        for (uint i=0; i<6; ++i)
        { 
            withdrawCollateral(bidders[i], nft);
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - prevBalance == 5 ether);
        for(uint i=0; i<4; ++i)
            require(bidders[i].balance == 10 ether);
        require(bidders[4].balance == 6 ether);
        require(bidders[5].balance == 9 ether);
    }

    function perm(uint256 n, uint256 seed) internal pure returns(uint256[] memory){
        uint256[] memory p = new uint256[](n);
        for(uint i=0; i<n; ++i)
            p[i] = i;

        for (uint i=n-1; i>0; --i){
            seed = uint256(keccak256(abi.encodePacked(seed)));
            uint j = seed % (i+1);
            (p[j], p[i]) = (p[i], p[j]);
        }
        return p;
    }

    function testPermutations(uint256 seed) public {
        uint256[] memory collateral = new uint256[](6);
        bytes32[] memory nonce = new bytes32[](6);
        uint88[] memory bidValue = new uint88[](6);
        uint8[] memory bidAmount = new uint8[](6);
        collateral[0] = 7 ether; collateral[1] = 6 ether; collateral[2] = 4 ether; 
        collateral[3] = 7 ether; collateral[4] = 6 ether; collateral[5] = 4 ether; 
        nonce[0] = bytes32("foo"); nonce[1] = bytes32("bar"); nonce[2] = bytes32("baz");
        nonce[3] = bytes32("foo"); nonce[4] = bytes32("bar"); nonce[5] = bytes32("baz");
        bidValue[0] = 3 ether; bidValue[1] = 3 ether; bidValue[2] = 3 ether;
        bidValue[3] = 6 ether; bidValue[4] = 5 ether; bidValue[5] = 2 ether;         
        bidAmount[0] = 2; bidAmount[1] = 2; bidAmount[2] = 2; 
        bidAmount[3] = 2; bidAmount[4] = 1; bidAmount[5] = 1; 

        uint256[] memory p = perm(6, seed);

        uint88 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for(uint i=0; i<6; ++i)
            commitBid(bidders[p[i]], nft, collateral[p[i]], nonce[p[i]], bidValue[p[i]], bidAmount[p[i]]);
        skip(2 hours);
        for(uint i=0; i<6; ++i)
            revealBid(bidders[p[i]], nft, nonce[p[i]], bidValue[p[i]], bidAmount[p[i]]);
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();
        for(uint i=0; i<6; ++i){
            //(uint88 payment, uint8 amount) = nft.outcomes(bidders[p[i]]);
            mint(bidders[p[i]], nft);
        }
        for(uint i=0; i<4; ++i)
            require(nft.balanceOf(bidders[i])==0);
        for(uint i=4; i<6; ++i)
            require(nft.balanceOf(bidders[i])==bidAmount[i]);
        for (uint i=0; i<6; ++i)
        { 
            withdrawCollateral(bidders[p[i]], nft);
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - prevBalance == 5 ether);
        for(uint i=0; i<4; ++i)
            require(bidders[i].balance == 10 ether);
        require(bidders[4].balance == 6 ether);
        require(bidders[5].balance == 9 ether);
    }

    function testLargeScale() public {
        for (uint256 i=10; i<800; ++i){
            string memory bidderName = string(abi.encodePacked("bidder", i.toString()));
            address bidderAddy = address(uint160(uint256(keccak256(bytes(bidderName))))); 
            bidders.push(bidderAddy);
            vm.label(bidderAddy, bidderName);
            vm.deal(bidderAddy, 10 ether);
            //console.log(bidderName, bidderAddy, bidderAddy.balance);
        }
        uint88 maxvalue = 10 ether;
        bytes32 nonce = bytes32("nonce");
        uint88[] memory bidValue = new uint88[](800);
        uint8[] memory bidAmount = new uint8[](800);
        //optval = 800 + 799 + ... + 751 = 38775 check // 27300 buggy
        //payment = 750 = 
        //opt without i = 38775 - i + 750
        //optval without vi = 38775 - i
        //payment = "opt without i" - (optval - vi ) = 38775 - i + 750 - (38775 - i) = 750
        //winners = bidder 751 to 800.
        for(uint i=0; i< 800; ++i)
        {
            bidValue[i] =  uint88(1 + i); //uint88(bytes11(keccak256(abi.encodePacked(bidders[i])))) % maxvalue;
            bidAmount[i] = 1; // + uint8(bytes1(keccak256(abi.encodePacked(bidValue[i])))) % 10;
        }

        uint88 reservePrice = 1;
        vm.prank(deployer);
        nftbig.createAuction(1, 4 hours, 4 hours, reservePrice);
        skip(2 minutes);
        for(uint i=0; i<800; ++i)
            commitBid(bidders[i], nftbig, maxvalue, nonce, bidValue[i], bidAmount[i]);
        skip(4 hours);
        for(uint i=0; i<800; ++i)
            revealBid(bidders[i], nftbig, nonce, bidValue[i], bidAmount[i]);
        skip(4 hours);

        if(false){
            vm.prank(deployer);
            nftbig.finalizeAuction();
        }
        else{
            uint startgas = gasleft();
            vm.prank(deployer);
            nftbig.finalizeAuctionStepA();
            uint endgas = gasleft();
            console.log('gas for 1st step', startgas - endgas);
            startgas = gasleft();
            vm.prank(deployer);
            nftbig.finalizeAuctionStepB();
            endgas = gasleft();
            console.log('gas for 2nd step', startgas - endgas);
            startgas = gasleft();
            vm.prank(deployer);
            nftbig.finalizeAuctionStepC();
            endgas = gasleft();
            console.log('gas for 3rd step', startgas - endgas);
        }
        
        for (uint i=0; i<800; ++i)
        { 
            mint(bidders[i], nftbig);
            withdrawCollateral(bidders[i], nftbig);
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nftbig.withdrawBalance();
        require(deployer.balance - prevBalance == 750*50);
        for(uint i=0; i<750; ++i)
        {
            require(bidders[i].balance == 10 ether, "weird balance");
            require(nftbig.balanceOf(bidders[i]) == 0, "got nft but should not");
        }
        for(uint i=750; i<800; ++i)
        {
            uint expected = 10 ether - 750;
            require(bidders[i].balance == expected, "weird balance");
            require(nftbig.balanceOf(bidders[i]) == 1, "should have 1 nft");
        }
    }
}
