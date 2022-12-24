// SPDX-License-Identifier: MIT
pragma solidity >=0.8.15;

import {Owned} from "@solbase/auth/Owned.sol";
import {ReentrancyGuard} from "@solbase/utils/ReentrancyGuard.sol";
import "@solbase/utils/SafeTransferLib.sol";
import "@solbase/utils/LibString.sol";
import {ERC721} from "./ERC721.sol";
import {IBotThisErrors} from "./IBotThisErrors.sol";
import "@solbase/utils/SSTORE2.sol";

import "forge-std/Test.sol";

// Simplified version of BotThis where every wallet can only bid on one NFT
contract BotThisSimple is Owned(tx.origin), ReentrancyGuard, ERC721, IBotThisErrors {
    using SafeTransferLib for address;
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuctionCreated(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint96 reservePrice);
    event AuctionCanceled();
    event AuctionFinalized();
    event BidCommited(address indexed sender, uint96 collateral, bytes20 commitment);
    event BidRevealed(address indexed sender, uint96 bidValue);


    // Possibly add events for withdrawCollateral, withdrawBalance, and emergencyReveal

    /*//////////////////////////////////////////////////////////////
                         METADATA STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

    uint32 public immutable collectionSize;
    //uint16 public immutable topBidders;

    enum Status {
        Ongoing,
        Finalized,
        Canceled
    }

    struct AuctionInfo {
        uint32 startTime;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint96 reservePrice;
        Status status;
    }
    // still 56 bits available in the slot

    /// @dev Representation of a sealed bid in storage. Occupies one slot.
    /// @param commitment The hash commitment of a bid value.
    /// @param collateral The amount of collateral backing the bid.
    struct SealedBid {
        bytes20 commitment;
        uint96 collateral;
    }

    /// @dev Representation of a revealed bid in storage. Occupies one slot.
    /// @param bidder  The bidder.
    /// @param value value actually bid (less or equal to collateral)
    struct RevealedBid {
        address bidder;
        uint96 value;
    }

    AuctionInfo public auction;
    // ====
    uint96 public mintPrice;
    uint96 public withdrawableBalance;
    uint32 public currentTokenId;
    // ====
    string public baseURI;
    mapping(address => SealedBid) public sealedBids;
    mapping(address => uint256) public winners;
    RevealedBid[] public revealedBids;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(string memory _name, string memory _symbol, uint32 _size) {
        name = _name;
        symbol = _symbol;
        collectionSize = _size;
    }


    /// @notice Sets the token URI
    function setURI(string calldata _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    /// @notice Creates an auction for the given ERC721 asset with the given
    ///         auction parameters.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period,
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    function createAuction(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint96 reservePrice)
        external
        onlyOwner
        nonReentrant
    {
        AuctionInfo memory theAuction = auction;

        if (startTime == 0) {
            startTime = uint32(block.timestamp);
        } else if (startTime < block.timestamp) {
            revert InvalidStartTimeError();
        }
        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError();
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError();
        }
        if (theAuction.startTime > 0) {
            if (block.timestamp > theAuction.startTime || theAuction.startTime > startTime) {
                revert InvalidStartTimeError();
            }
        }
        theAuction.startTime = startTime;
        theAuction.endOfBiddingPeriod = startTime + bidPeriod;
        theAuction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
        theAuction.reservePrice = reservePrice;

        auction = theAuction;

        emit AuctionCreated(startTime, bidPeriod, revealPeriod, reservePrice);
    }

    /// @notice Commits to a bid. If a bid was
    ///         previously committed to, overwrites the previous commitment.
    ///         Value attached to this call is added as collateral for the bid.
    /// @param commitment The commitment to the bid, computed as
    ///        `bytes20(keccak256(abi.encode(nonce, bidValue, bidAmount, address(this))))`.
    function commitBid(bytes20 commitment) external payable {
        if (commitment == bytes20(0)) {
            revert ZeroCommitmentError();
        }

        AuctionInfo memory theAuction = auction;

        if (block.timestamp < theAuction.startTime || block.timestamp > theAuction.endOfBiddingPeriod) {
            revert NotInBidPeriodError();
        }

        SealedBid storage bid = sealedBids[msg.sender];
        bid.commitment = commitment;
        uint96 value = uint96(msg.value);
        if (msg.value != 0) {
            bid.collateral += value;
        }
        if (bid.collateral < theAuction.reservePrice) {
            revert CollateralLessThanReservePriceError();
        }
        emit BidCommited(msg.sender, value, commitment);
    }

    /// @notice Reveals the value and amount of a bid that was previously committed to.
    /// @param nonce The random input used to obfuscate the commitment.
    /// @param bidValue The value of the bid.
    function revealBid(bytes32 nonce, uint96 bidValue) external nonReentrant {
        AuctionInfo memory theAuction = auction;

        if (block.timestamp <= theAuction.endOfBiddingPeriod || block.timestamp > theAuction.endOfRevealPeriod) {
            revert NotInRevealPeriodError();
        }

        SealedBid storage bid = sealedBids[msg.sender];

        // Check that the opening is valid
        bytes20 bidHash = bytes20(keccak256(abi.encode(nonce, bidValue, address(this))));
        if (bidHash != bid.commitment) {
            revert InvalidSimpleOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes20(0);
        }

        uint96 collateral = bid.collateral;
        if (collateral < bidValue || bidValue < theAuction.reservePrice) {
            // Return collateral in any of the following cases
            // - undercollateralized bid
            // - bid price below reserve price
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            addRevealedBid(msg.sender, bidValue);
            emit BidRevealed(msg.sender, bidValue);
        }
    }

    /// @notice Adds a bid to the revealedBids heap. Rearranges revealedBids to maintain heap invariant among the top collectionSize+1 bidders.
    /// @param account The account submitting the bid.
    /// @param bidValue The value of the bid.
    function addRevealedBid(address account, uint96 bidValue) internal {
        RevealedBid memory newBid = RevealedBid({bidder: account, value: bidValue});
        if (revealedBids.length < collectionSize+1) {
            revealedBids.push(newBid);
            siftDown(revealedBids.length - 1);
            winners[account] = 2;
        } else {
            // we have reached capacity
            // check whether this bid has a higher price than the smallest price in the heap
            // if so move it in the heap of top bidders otherwise just append it
            RevealedBid memory popCandidate = revealedBids[0];
            if (bidValue > popCandidate.value) {
                revealedBids.push(popCandidate);
                revealedBids[0] = newBid;
                siftUp();
                winners[popCandidate.bidder] = 1;
                winners[account] = 2;
            } else {
                revealedBids.push(newBid);
                winners[account] = 1;
            }
        }
    }

    /// @notice Allows a user with a sealed bid to open it after the auction has been finalized.
    ///         Useful if a user could not open their bid during reveal time (lost the nonce, fell asleep, etc.)
    function emergencyReveal() external {
        AuctionInfo memory theAuction = auction;
        if (theAuction.status == Status.Ongoing) {
            revert AuctionNotFinalizedError();
        }

        SealedBid storage bid = sealedBids[msg.sender];
        // Mark as open
        bid.commitment = bytes20(0);
    }

    /// @notice Withdraws collateral. If msg.sender has to pay for an NFT, the payment is subtracted.
    function withdrawCollateral() external nonReentrant {
        AuctionInfo memory theAuction = auction;
        SealedBid storage bid = sealedBids[msg.sender];
        if (bid.commitment != bytes20(0)) {
            revert UnrevealedBidError();
        }
        if (theAuction.status == Status.Ongoing) {
            revert AuctionNotFinalizedError();
        }
        uint96 refund = bid.collateral;
        // Return remainder
        if (refund > 0) {
            if (winners[msg.sender] > 1){
                refund -= mintPrice;
            }
            bid.collateral = 0;
            msg.sender.safeTransferETH(refund);
        }
    }

    /// @notice Cancels the auction. Nobody gets any NFTs. Bidders can withdraw their collateral.
    function cancelAuction() external onlyOwner {
        AuctionInfo memory theAuction = auction;
        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }
        auction.status = Status.Canceled;
        emit AuctionCanceled();
    }

    /// @notice Finalizes the auction by computing the winners and their payments.
    function finalizeAuction() external onlyOwner {
        AuctionInfo memory theAuction = auction;

        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }
        RevealedBid memory minimumInHeap = revealedBids[0];
        uint256 len = revealedBids.length;
        if (len <= collectionSize)
        {
            mintPrice = theAuction.reservePrice;
            withdrawableBalance = uint96(len * theAuction.reservePrice);
        }
        else 
        {
            mintPrice = minimumInHeap.value;
            withdrawableBalance = uint96(collectionSize * minimumInHeap.value);
            winners[minimumInHeap.bidder] = 1;
        }
        auction.status = Status.Finalized;
        emit AuctionFinalized();
    }

    /// @notice Mints any NFTs that were awarded to msg.sender during the auction
    function mint() external nonReentrant {
        if (auction.status != Status.Finalized) {
            revert AuctionNotFinalizedError();
        }
        if (winners[msg.sender] == 2){
            winners[msg.sender] = 3;
            _safeMint(msg.sender, currentTokenId++);
        }
    }

    /// @notice Lets the owner withdraw the proceeds of the auction
    function withdrawBalance() external onlyOwner {
        uint256 amount = withdrawableBalance;
        withdrawableBalance = 0;
        msg.sender.safeTransferETH(amount);
    }

    /// @notice return the token URI
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, tokenId.toString())) : "";
    }

    /// @dev Restore the heap invariant assuming 'revealedBids' is a heap except possibly for pos.
    function siftDown(uint256 pos) internal {
        RevealedBid memory newItem = revealedBids[pos];
        // Follow the path to the root, moving parents down until finding a place newItem fits.
        while (pos > 0) {
            uint256 parentpos = (pos - 1) >> 1;
            RevealedBid memory parent = revealedBids[parentpos];
            if (newItem.value < parent.value) {
                revealedBids[pos] = parent;
                pos = parentpos;
                continue;
            }
            break;
        }
        revealedBids[pos] = newItem;
    }

    /// @dev Restore the heap invariant assuming revealedBids[1] and revealedBids[2] are heaps but revealedBids[0] is possibly not.
    function siftUp() internal {
        uint256 endpos = collectionSize + 1;
        uint256 pos = 0;
        RevealedBid memory newItem = revealedBids[pos];
        uint256 leftpos = (pos << 1) + 1;
        while (leftpos < endpos) {

            RevealedBid memory left = revealedBids[leftpos];
            uint256 minpos = leftpos;
            RevealedBid memory minItem = left;
            uint256 rightpos = leftpos + 1;
            if (rightpos < endpos){
                RevealedBid memory right = revealedBids[rightpos];
                if (right.value < left.value) {
                    minpos = rightpos;
                    minItem = right; 
                }
            }
            if (newItem.value < minItem.value) {
                // pos is the right place to insert newItem
                break;
            }
            else {
                // move the min item to the parent recurse on minpos
                revealedBids[pos] = minItem;
                pos = minpos;
                leftpos = (pos << 1) + 1;
            }
        }
        // pos now points either to a leaf or an empty internal node 
        // whose both children are smaller than newItem
        // we can insert newItem here
        revealedBids[pos] = newItem;
    }
}
