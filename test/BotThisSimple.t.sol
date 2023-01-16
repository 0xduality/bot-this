// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/tokens/BotThisSimple.sol";
import "../src/tokens/IBotThisErrors.sol";
import "@solbase/utils/LibString.sol";
import {Owned} from "@solbase/auth/Owned.sol";

contract BotThisSimpleTest is Test, IBotThisErrors {
    using stdStorage for StdStorage;
    using LibString for uint256;

    address[] public bidders;
    address deployer;
    BotThisSimple public nft;
    BotThisSimple public nftbig;

    function commitBid(address from, BotThisSimple to, uint256 collateral, bytes32 nonce, uint96 bidValue)
        private
        returns (bytes20 commitment)
    {
        commitment = bytes20(keccak256(abi.encode(nonce, bidValue, address(to))));
        vm.prank(from);
        to.commitBid{value: collateral}(commitment);
        return commitment;
    }

    function revealBid(address from, BotThisSimple to, bytes32 nonce, uint96 bidValue) private {
        vm.prank(from);
        to.revealBid(nonce, bidValue);
    }

    function mint(address from, BotThisSimple to) private {
        vm.prank(from);
        to.mint();
    }

    function withdrawCollateral(address from, BotThisSimple to) private {
        vm.prank(from);
        to.withdrawCollateral();
    }

    function setUp() public {
        nft = new BotThisSimple("BotThisSimple", "BTS", 2);
        nftbig = new BotThisSimple("BotThis2", "BT2", 10000);

        deployer = tx.origin;
        for (uint256 i = 0; i < 10; ++i) {
            string memory bidderName = string(abi.encodePacked("bidder", i.toString()));
            address bidderAddy = address(uint160(uint256(keccak256(bytes(bidderName)))));
            bidders.push(bidderAddy);
            vm.label(bidderAddy, bidderName);
            vm.deal(bidderAddy, 10 ether);
        }
    }

    function testHappyCase() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        uint256 i = 0;
        for (i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 hours);
        for (i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();
        for (i = 0; i < 3; ++i) {
            mint(bidders[i], nft);
        }
        require(nft.balanceOf(bidders[0]) == 1);
        require(nft.balanceOf(bidders[1]) == 1);
        require(nft.balanceOf(bidders[2]) == 0);

        for (i = 0; i < 3; ++i) {
            withdrawCollateral(bidders[i], nft);
        }
        i = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - i == 4 ether);
        require(bidders[0].balance == 8 ether);
        require(bidders[1].balance == 8 ether);
        require(bidders[2].balance == 10 ether);

        vm.prank(deployer);
        nft.setURI("ipfs://hash/");
        console.log(nft.tokenURI(0));
        vm.prank(bidders[0]);
        nft.approve(bidders[2], 0);
        vm.prank(bidders[1]);
        nft.setApprovalForAll(bidders[2], true);
        vm.prank(bidders[2]);
        nft.safeTransferFrom(bidders[0], bidders[2], 0);
        vm.prank(bidders[2]);
        nft.safeTransferFrom(bidders[1], bidders[2], 1);
        require(nft.balanceOf(bidders[2]) == 2);
        require(nft.balanceOf(bidders[1]) == 0);
        //require(nft.balanceOf(bidders[0]) == 0);
    }

    function testOnlyOwnerCreateAuction() public {
        uint96 reservePrice = 1 ether;
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
    }

    function testCreateAuctionMisconfiguration() public {
        uint96 reservePrice = 1 ether;
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
        uint96 reservePrice = 1 ether;
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
        uint96 reservePrice = 1 ether;

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp + 30 minutes), 2 hours, 2 hours, reservePrice);
        skip(20 minutes);
        vm.prank(bidders[0]);
        vm.expectRevert(NotInBidPeriodError.selector);
        nft.commitBid{value: 2 ether}(bytes20("commitment"));
        skip(20 minutes);
        vm.prank(bidders[0]);
        vm.expectRevert(ZeroCommitmentError.selector);
        nft.commitBid{value: 2 ether}(bytes20(0));
        vm.prank(bidders[0]);
        vm.expectRevert(CollateralLessThanReservePriceError.selector);
        nft.commitBid{value: 0 ether}(bytes20("commitment"));
        skip(5 hours);
        vm.prank(bidders[0]);
        vm.expectRevert(NotInBidPeriodError.selector);
        nft.commitBid{value: 2 ether}(bytes20("commitment"));
    }

    function testBadReveals() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for (uint256 i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 minutes);
        vm.expectRevert(NotInRevealPeriodError.selector);
        revealBid(bidders[0], nft, nonce[0], bidValue[0]);
        skip(2 hours);
        (bytes20 commitment,) = nft.sealedBids(bidders[0]);
        bytes20 badNonceCommitment = bytes20(keccak256(abi.encode(nonce[1], bidValue[0], address(nft))));
        vm.expectRevert(abi.encodeWithSelector(InvalidSimpleOpeningError.selector, badNonceCommitment, commitment));
        revealBid(bidders[0], nft, nonce[1], bidValue[0]);
        revealBid(bidders[0], nft, nonce[0], bidValue[0]);
        skip(5 hours);
        vm.expectRevert(NotInRevealPeriodError.selector);
        revealBid(bidders[1], nft, nonce[1], bidValue[1]);
    }

    function testSneakyBids() public {
        uint96 reservePrice = 3 ether;

        uint256[] memory collateral = new uint256[](2);
        bytes32[] memory nonce = new bytes32[](2);
        uint96[] memory bidValue = new uint96[](2);
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        collateral[0] = 6 ether;
        collateral[1] = 4 ether;
        bidValue[0] = 7 ether;
        bidValue[1] = 2 ether;

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for (uint256 i = 0; i < 2; ++i) {
            require(bidders[i].balance == 10 ether, "Precondition not met");
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
            require(bidders[i].balance < 10 ether, "Collateral not posted");
        }
        skip(2 hours);
        for (uint256 i = 0; i < 2; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
            require(bidders[i].balance == 10 ether, "Sneaky bidder not refunded");
        }
    }

    function testEmergencyReveal() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        for (uint256 i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        vm.prank(bidders[0]);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        nft.emergencyReveal();
        skip(2 hours);
        for (uint256 i = 1; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
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
        for (uint256 i = 0; i < 3; ++i) {
            withdrawCollateral(bidders[i], nft);
        }
        require(bidders[0].balance == 10 ether, "emergencyReveal did not work");
    }

    function testWithdrawCollateral() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 6 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;

        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        for (uint256 i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        vm.expectRevert(UnrevealedBidError.selector);
        withdrawCollateral(bidders[0], nft);
        skip(2 hours);
        for (uint256 i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        withdrawCollateral(bidders[0], nft);
        vm.prank(deployer);
        nft.finalizeAuction();

        for (uint256 i = 0; i < 3; ++i) {
            withdrawCollateral(bidders[i], nft);
            withdrawCollateral(bidders[i], nft);
        }
    }

    function testCancelAuction() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 6 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        for (uint256 i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.cancelAuction();
        for (uint256 i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.cancelAuction();
        vm.prank(deployer);
        nft.cancelAuction();
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        for (uint256 i = 0; i < 3; ++i) {
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
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        for (uint256 i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.prank(deployer);
        vm.expectRevert(WaitUntilAfterRevealError.selector);
        nft.finalizeAuction();
        for (uint256 i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.finalizeAuction();
        vm.prank(deployer);
        nft.finalizeAuction();
        for (uint256 i = 0; i < 3; ++i) {
            mint(bidders[i], nft);
            withdrawCollateral(bidders[i], nft);
        }
        vm.prank(deployer);
        nft.withdrawBalance();
    }

    function testMint() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        skip(2 minutes);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        uint256 i;
        for (i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        for (i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.expectRevert(AuctionNotFinalizedError.selector);
        mint(bidders[1], nft);
        vm.prank(deployer);
        nft.finalizeAuction();
        for (i = 0; i < 2; ++i) {
            mint(bidders[0], nft);
            require(nft.balanceOf(bidders[0]) == 1);
            mint(bidders[1], nft);
            require(nft.balanceOf(bidders[1]) == 1);
            mint(bidders[2], nft);
            require(nft.balanceOf(bidders[2]) == 0);
        }
        for (i = 0; i < 3; ++i) {
            withdrawCollateral(bidders[i], nft);
        }
        i = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - i == 4 ether);
        require(bidders[0].balance == 8 ether);
        require(bidders[1].balance == 8 ether);
        require(bidders[2].balance == 10 ether);
    }

    function testWithdrawBalance() public {
        uint256[] memory collateral = new uint256[](3);
        bytes32[] memory nonce = new bytes32[](3);
        uint96[] memory bidValue = new uint96[](3);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        bidValue[0] = 3 ether;
        bidValue[1] = 5 ether;
        bidValue[2] = 2 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.withdrawBalance();

        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 minutes);
        uint256 i;
        for (i = 0; i < 3; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 hours);
        for (i = 0; i < 3; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        vm.prank(deployer);
        nft.withdrawBalance();

        skip(2 hours);
        vm.prank(deployer);
        nft.withdrawBalance();

        vm.prank(deployer);
        nft.finalizeAuction();

        i = deployer.balance;
        vm.expectRevert(Owned.Unauthorized.selector);
        nft.withdrawBalance();
        vm.prank(deployer);
        nft.withdrawBalance();
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - i == 4 ether);

        mint(bidders[0], nft);
        require(nft.balanceOf(bidders[0]) == 1);
        mint(bidders[1], nft);
        require(nft.balanceOf(bidders[1]) == 1);
    }

    function testOverCapacity() public {
        uint256[] memory collateral = new uint256[](6);
        bytes32[] memory nonce = new bytes32[](6);
        uint96[] memory bidValue = new uint96[](6);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        collateral[3] = 7 ether;
        collateral[4] = 6 ether;
        collateral[5] = 7 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        nonce[3] = bytes32("foo");
        nonce[4] = bytes32("bar");
        nonce[5] = bytes32("baz");
        bidValue[0] = 1 ether;
        bidValue[1] = 1 ether;
        bidValue[2] = 1 ether;
        bidValue[3] = 2 ether;
        bidValue[4] = 3 ether;
        bidValue[5] = 5 ether;

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        uint256 i;
        for (i = 0; i < 6; ++i) {
            commitBid(bidders[i], nft, collateral[i], nonce[i], bidValue[i]);
        }
        skip(2 hours);
        for (i = 0; i < 6; ++i) {
            revealBid(bidders[i], nft, nonce[i], bidValue[i]);
        }
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();
        for (i = 0; i < 6; ++i) {
            mint(bidders[i], nft);
        }
        for (i = 0; i < 4; ++i) {
            require(nft.balanceOf(bidders[i]) == 0);
        }
        for (i = 4; i < 6; ++i) {
            require(nft.balanceOf(bidders[i]) == 1);
        }
        for (i = 0; i < 6; ++i) {
            withdrawCollateral(bidders[i], nft);
        }
        i = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - i == 4 ether);
        for (i = 0; i < 4; ++i) {
            require(bidders[i].balance == 10 ether);
        }
        require(bidders[4].balance == 8 ether);
        require(bidders[5].balance == 8 ether);
    }

    function perm(uint256 n, uint256 seed) internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            p[i] = i;
        }

        for (uint256 i = n - 1; i > 0; --i) {
            seed = uint256(keccak256(abi.encodePacked(seed)));
            uint256 j = seed % (i + 1);
            (p[j], p[i]) = (p[i], p[j]);
        }
        return p;
    }

    function testPermutations(uint256 seed) public {
        uint256[] memory collateral = new uint256[](6);
        bytes32[] memory nonce = new bytes32[](6);
        uint96[] memory bidValue = new uint96[](6);
        collateral[0] = 7 ether;
        collateral[1] = 6 ether;
        collateral[2] = 4 ether;
        collateral[3] = 7 ether;
        collateral[4] = 6 ether;
        collateral[5] = 6 ether;
        nonce[0] = bytes32("foo");
        nonce[1] = bytes32("bar");
        nonce[2] = bytes32("baz");
        nonce[3] = bytes32("foo");
        nonce[4] = bytes32("bar");
        nonce[5] = bytes32("baz");
        bidValue[0] = 1 ether;
        bidValue[1] = 1 ether;
        bidValue[2] = 1 ether;
        bidValue[3] = 2 ether;
        bidValue[4] = 3 ether;
        bidValue[5] = 5 ether;

        uint256[] memory p = perm(6, seed);

        uint96 reservePrice = 1 ether;
        vm.prank(deployer);
        nft.createAuction(uint32(block.timestamp), 2 hours, 2 hours, reservePrice);
        skip(2 minutes);
        uint256 i;
        for (i = 0; i < 6; ++i) {
            commitBid(bidders[p[i]], nft, collateral[p[i]], nonce[p[i]], bidValue[p[i]]);
        }
        skip(2 hours);
        for (i = 0; i < 6; ++i) {
            revealBid(bidders[p[i]], nft, nonce[p[i]], bidValue[p[i]]);
        }
        skip(2 hours);
        vm.prank(deployer);
        nft.finalizeAuction();

        for (i = 0; i < 6; ++i) {
            mint(bidders[p[i]], nft);
        }
        for (i = 0; i < 4; ++i) {
            require(nft.balanceOf(bidders[i]) == 0);
        }
        for (i = 4; i < 6; ++i) {
            require(nft.balanceOf(bidders[i]) == 1);
        }
        for (i = 0; i < 6; ++i) {
            withdrawCollateral(bidders[p[i]], nft);
        }
        i = deployer.balance;
        vm.prank(deployer);
        nft.withdrawBalance();
        require(deployer.balance - i == 4 ether);
        for (i = 0; i < 4; ++i) {
            require(bidders[i].balance == 10 ether);
        }
        require(bidders[4].balance == 8 ether);
        require(bidders[5].balance == 8 ether);
    }

    function testLargeScale() public {
        for (uint256 i = 10; i < 11000; ++i) {
            string memory bidderName = string(abi.encodePacked("bidder", i.toString()));
            address bidderAddy = address(uint160(uint256(keccak256(bytes(bidderName)))));
            bidders.push(bidderAddy);
            vm.label(bidderAddy, bidderName);
            vm.deal(bidderAddy, 10 ether);
        }
        uint96 maxvalue = 10 ether;
        bytes32 nonce = bytes32("nonce");
        uint96[] memory bidValue = new uint96[](11000);

        for (uint256 i = 0; i < 11000; ++i) {
            bidValue[i] = uint96(1 + i);
        }

        uint96 reservePrice = 1;
        vm.prank(deployer);
        nftbig.createAuction(1, 4 hours, 4 hours, reservePrice);
        skip(2 minutes);
        for (uint256 i = 0; i < 11000; ++i) {
            commitBid(bidders[i], nftbig, maxvalue, nonce, bidValue[i]);
        }
        skip(4 hours);
        for (uint256 i = 0; i < 11000; ++i) {
            revealBid(bidders[i], nftbig, nonce, bidValue[i]);
        }
        skip(4 hours);

        vm.prank(deployer);
        uint s = gasleft();
        nftbig.finalizeAuction();
        console.log("Simple Finalization gas", s-gasleft());

        for (uint256 i = 0; i < 11000; ++i) {
            mint(bidders[i], nftbig);
            withdrawCollateral(bidders[i], nftbig);
        }
        uint256 prevBalance = deployer.balance;
        vm.prank(deployer);
        nftbig.withdrawBalance();

        uint256 N = nftbig.collectionSize();
        require(deployer.balance - prevBalance == (11000 - N) * N);
        for (uint256 i = 0; i < 11000 - N; ++i) {
            require(bidders[i].balance == maxvalue, "weird balance loser");
            require(nftbig.balanceOf(bidders[i]) == 0, "got nft but should not");
        }
        for (uint256 i = 11000 - N; i < 11000; ++i) {
            uint256 expected = maxvalue - (11000 - N);
            require(bidders[i].balance == expected, "weird balance winner");
            require(nftbig.balanceOf(bidders[i]) == 1, "should have 1 nft");
        }
    }
    /*    */
}
