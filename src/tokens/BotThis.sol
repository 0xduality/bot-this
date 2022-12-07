// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Owned} from "@solbase/auth/Owned.sol";
import {ReentrancyGuard} from "@solbase/utils/ReentrancyGuard.sol";


interface BotThisErrors {
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
}


contract BotThis is Owned(tx.origin), ReentrancyGuard, ERC721  {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/


    /*//////////////////////////////////////////////////////////////
                         METADATA STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

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
        uint8  collectionSize;
        Status status; 
        // still 56 bits available in this slot
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

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
        if (bidPeriod < 8 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 8 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }
        // if the auction has been initialized but it's not in the bidding period we can move it further into the future

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
            reservePrice,
            items
        );
    }
}
