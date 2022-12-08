// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Owned} from "@solbase/auth/Owned.sol";
import {ReentrancyGuard} from "@solbase/utils/ReentrancyGuard.sol";
import "@solbase/utils/SafeTransferLib.sol";
import {ERC721} from "./ERC721.sol";


//library BotThisErrors {
    error AlreadyStartedError();
    error RevealPeriodOngoingError();
    error BidPeriodOngoingError();
    error InvalidSeller(address sender, address seller);
    error InvalidAuctionIndexError(uint64 index);
    error BidPeriodTooShortError(uint32 bidPeriod);
    error RevealPeriodTooShortError(uint32 revealPeriod);
    error NotInRevealPeriodError();
    error NotInBidPeriodError();
    error UnrevealedBidError();
    error CannotWithdrawError();
    error ZeroCommitmentError();
    error InvalidStartTimeError(uint32 startTime);
    error InvalidOpeningError(bytes21 bidHash, bytes21 commitment);
//}


contract BotThis is Owned(tx.origin), ReentrancyGuard, ERC721  {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuctionCreated(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint88 reservePrice);
    event BidRevealed(address indexed sender, uint88 bidValue, uint8 bidAmount);

    /*//////////////////////////////////////////////////////////////
                         METADATA STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

    uint8 immutable public collectionSize;

    enum Status {
        Uninitialized,
        Initialized,
        Finalized,
        Canceled
    }

    struct AuctionInfo{
        uint32 startTime;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint88 reservePrice;
        Status status; 
        // still 64 bits available in this slot
    }

    /// @dev Representation of a sealed bid in storage. Occupies one slot.
    /// @param commitment The hash commitment of a bid value. 
    /// @param collateral The amount of collateral backing the bid.
    struct SealedBid {
        bytes21 commitment;
        uint88 collateral;
    }

    /// @dev Representation of a revealed bid in storage. Occupies one slot.
    /// @param bidder  The bidder. 
    /// @param amount amount of items asked.
    /// @param value value actually bid (less or equal to collateral)
    struct RevealedBid {
        address bidder;
        uint8   amount;
        uint88  value;
    }

    AuctionInfo public auction;
    mapping(address => SealedBid) public sealedBids;
    mapping(address => uint256) public payments;
    RevealedBid[] public revealedBids;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(string memory _name, string memory _symbol, uint8 _size) {
        name = _name;
        symbol = _symbol;
        collectionSize = _size;
    }

    /// @notice Creates an auction for the given ERC721 asset with the given
    ///         auction parameters.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    function createAuction(
        uint32 startTime, 
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint88 reservePrice
    ) 
        external 
        onlyOwner
        nonReentrant
    {
        AuctionInfo memory theAuction = auction;

        if(theAuction.status != Status.Uninitialized && theAuction.status != Status.Initialized)
            revert AlreadyStartedError();

        if (startTime == 0) {
            startTime = uint32(block.timestamp);
        } else if (startTime < block.timestamp) {
            revert InvalidStartTimeError(startTime);
        }
        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }
        if (theAuction.startTime > 0)
        {
            if (block.timestamp > theAuction.startTime || theAuction.startTime > startTime)
                revert InvalidStartTimeError(startTime);
        }
        theAuction.startTime = startTime;
        theAuction.endOfBiddingPeriod = startTime + bidPeriod;
        theAuction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
        theAuction.reservePrice = reservePrice;
        theAuction.status = Status.Initialized;

        auction = theAuction;
        
        emit AuctionCreated(
            startTime,
            bidPeriod,
            revealPeriod,
            reservePrice
        );
    }

    /// @notice Commits to a bid. If a bid was
    ///         previously committed to, overwrites the previous commitment.
    ///         Value attached to this call is added as collateral for the bid.
    /// @param commitment The commitment to the bid, computed as
    ///        `bytes21(keccak256(abi.encode(nonce, bidValue, bidAmount, address(this))))`.
    function commitBid(bytes21 commitment
    )
        external
        payable
        nonReentrant
    {
        if (commitment == bytes21(0)) {
            revert ZeroCommitmentError();
        }

        AuctionInfo memory theAuction = auction;

        if (
            block.timestamp < theAuction.startTime || 
            block.timestamp > theAuction.endOfBiddingPeriod
        ) {
            revert NotInBidPeriodError();
        }

        SealedBid storage bid = sealedBids[msg.sender];
        bid.commitment = commitment;
        if (msg.value != 0) {
            bid.collateral += uint88(msg.value);
        }
    }

    /// @notice Reveals the value and amount of a bid that was previously committed to. 
    /// @param bidAmount The amount of the bid.
    /// @param bidValue The value of the bid.
    /// @param nonce The random input used to obfuscate the commitment.
    function revealBid(
        uint8 bidAmount,
        uint88 bidValue,
        bytes32 nonce
    )
        external
        nonReentrant
    {
        AuctionInfo memory theAuction = auction;

        if (
            block.timestamp <= theAuction.endOfBiddingPeriod ||
            block.timestamp > theAuction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriodError();
        }

        SealedBid storage bid = sealedBids[msg.sender];

        // Check that the opening is valid
        bytes21 bidHash = bytes21(keccak256(abi.encode(
            nonce,
            bidValue,
            bidAmount,
            address(this))));
        if (bidHash != bid.commitment) {
            revert InvalidOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes21(0);
        }

        uint88 collateral = bid.collateral;
        if (collateral < bidValue || bidValue < auction.reservePrice || bidAmount > collectionSize) {
            // Return collateral
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else { 
            revealedBids.push(RevealedBid({bidder: msg.sender, amount: bidAmount, value: bidValue}));

            emit BidRevealed(
                msg.sender,
                bidValue, 
                bidAmount
            );
        }
    }
}
