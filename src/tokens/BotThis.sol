// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Owned} from "@solbase/auth/Owned.sol";
import {ReentrancyGuard} from "@solbase/utils/ReentrancyGuard.sol";
import "@solbase/utils/SafeTransferLib.sol";
import "@solbase/utils/LibString.sol";
import {ERC721} from "./ERC721.sol";
import {IBotThisErrors} from "./IBotThisErrors.sol";

import "forge-std/Test.sol";

contract BotThis is Owned(tx.origin), ReentrancyGuard, ERC721, IBotThisErrors {
    using SafeTransferLib for address;
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AuctionCreated(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint88 reservePrice);
    event BidRevealed(address indexed sender, uint88 bidValue, uint8 bidAmount);

    /*//////////////////////////////////////////////////////////////
                         METADATA STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/

    uint8 public immutable collectionSize;
    uint16 public immutable topBidders;

    enum Status {
        Ongoing,
        Finalized,
        Canceled
    }

    struct AuctionInfo {
        uint32 startTime;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint88 reservePrice;
        Status status;
    }
    // still 64 bits available in this slot

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
        uint8 amount;
        uint88 value;
    }

    /// @dev Representation of an auction outcome. Occupies one slot.
    /// @param payment payment to be paid.
    /// @param amount Amount of items awarded.
    struct Outcome {
        uint88 payment;
        uint8 amount;
    }

    AuctionInfo public auction;
    // ====
    uint248 public withdrawableBalance;
    uint8 public currentTokenId;
    // ====
    string public baseURI;
    mapping(address => SealedBid) public sealedBids;
    mapping(address => Outcome) public outcomes;
    RevealedBid[] public revealedBids;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(string memory _name, string memory _symbol, uint8 _size, uint16 _topBidders) {
        if ((_topBidders & 1) == 1) {
            revert TopBiddersOddError();
        }
        name = _name;
        symbol = _symbol;
        collectionSize = _size;
        topBidders = _topBidders;
    }

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
    function createAuction(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint88 reservePrice)
        external
        onlyOwner
        nonReentrant
    {
        AuctionInfo memory theAuction = auction;

        if (theAuction.status != Status.Ongoing) {
            revert AlreadyStartedError();
        }

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
        if (theAuction.startTime > 0) {
            if (block.timestamp > theAuction.startTime || theAuction.startTime > startTime) {
                revert InvalidStartTimeError(startTime);
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
    ///        `bytes21(keccak256(abi.encode(nonce, bidValue, bidAmount, address(this))))`.
    function commitBid(bytes21 commitment) external payable nonReentrant {
        if (commitment == bytes21(0)) {
            revert ZeroCommitmentError();
        }

        AuctionInfo memory theAuction = auction;

        if (block.timestamp < theAuction.startTime || block.timestamp > theAuction.endOfBiddingPeriod) {
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
    function revealBid(bytes32 nonce, uint88 bidValue, uint8 bidAmount) external nonReentrant {
        AuctionInfo memory theAuction = auction;

        if (block.timestamp <= theAuction.endOfBiddingPeriod || block.timestamp > theAuction.endOfRevealPeriod) {
            revert NotInRevealPeriodError();
        }

        SealedBid storage bid = sealedBids[msg.sender];

        // Check that the opening is valid
        bytes21 bidHash = bytes21(keccak256(abi.encode(nonce, bidValue, bidAmount, address(this))));
        if (bidHash != bid.commitment) {
            revert InvalidOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes21(0);
        }

        uint88 collateral = bid.collateral;
        if (collateral < bidValue || bidValue < theAuction.reservePrice || bidAmount > collectionSize) {
            // Return collateral
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            addRevealedBid(msg.sender, bidAmount, bidValue);
            emit BidRevealed(msg.sender, bidValue, bidAmount);
        }
    }

    function addRevealedBid(address account, uint8 bidAmount, uint88 bidValue) internal {
        RevealedBid memory newBid = RevealedBid({bidder: account, amount: bidAmount, value: bidValue});
        if (revealedBids.length < topBidders) {
            revealedBids.push(newBid);
            siftDown(revealedBids.length - 1);
        } else {
            // we have reached capacity
            // check whether the bid is has a higher price than the smallest price in topBidders
            // if so move it in the heap of topBidders otherwise just append it
            RevealedBid memory popCandidate = revealedBids[0];
            if (bidValue * popCandidate.amount > popCandidate.value * bidAmount) {
                revealedBids.push(popCandidate);
                revealedBids[0] = newBid;
                siftUp();
            } else {
                revealedBids.push(newBid);
            }
        }
    }

    /// @notice Allows a user with a sealed bid to open it after the auction was finalized.
    ///         Useful if a user could not open their bid during reveal time (lost the nonce, fell asleep, etc.)
    function emergencyReveal() external {
        AuctionInfo memory theAuction = auction;
        if (theAuction.status == Status.Ongoing) {
            revert AuctionNotFinalizedError();
        }

        SealedBid storage bid = sealedBids[msg.sender];

        if (bid.commitment != bytes21(0)) {
            // Mark as open
            bid.commitment = bytes21(0);
        }
    }

    /// @notice Withdraws collateral.
    function withdrawCollateral() external nonReentrant {
        AuctionInfo memory theAuction = auction;
        SealedBid storage bid = sealedBids[msg.sender];
        if (bid.commitment != bytes21(0)) {
            revert UnrevealedBidError();
        }
        if (theAuction.status == Status.Ongoing) {
            revert AuctionNotFinalizedError();
        }
        Outcome memory outcome = outcomes[msg.sender];
        // Return remainder
        uint88 remainder = bid.collateral - outcome.payment;
        bid.collateral = 0;
        msg.sender.safeTransferETH(remainder);
    }

    function cancelAuction() external nonReentrant {
        AuctionInfo memory theAuction = auction;

        if (block.timestamp <= theAuction.endOfBiddingPeriod) {
            revert BidPeriodOngoingError();
        } else if (block.timestamp <= theAuction.endOfRevealPeriod) {
            revert RevealPeriodOngoingError();
        }
        auction.status = Status.Canceled;
    }

    /// @notice Finalizes the auction. Can only do so if the bid reveal
    ///         phase is over.
    function finalizeAuction() external nonReentrant {
        AuctionInfo memory theAuction = auction;

        if (block.timestamp <= auction.endOfBiddingPeriod) {
            revert BidPeriodOngoingError();
        } else if (block.timestamp <= auction.endOfRevealPeriod) {
            revert RevealPeriodOngoingError();
        }

        // add dummy buyers at the reserve price
        for (uint8 i = 128; i > 0; i >>= 1) {
            if (i <= collectionSize)
                addRevealedBid(address(uint160(i)), i, i * theAuction.reservePrice);
        }

        auction.status = Status.Finalized;

        vcg2();
    }

    /// @notice vcg2
    function vcg2() internal
    {
        uint256 len = revealedBids.length < topBidders ? revealedBids.length : topBidders;
        uint256[] memory values = new uint256[](len);
        uint8[] memory amounts = new uint8[](len);
        address[] memory bidders = new address[](len);
        uint8 stride = collectionSize + 1;
        for (uint256 i; i<len; ++i){
            RevealedBid memory rbi = revealedBids[i];
            bidders[i] = rbi.bidder;
            values[i] = rbi.value;
            amounts[i] = rbi.amount;
        }
        uint256[] memory forward_table = new uint256[](len*stride);
        uint8 wi = amounts[0];
        uint256 vi = values[0];
        for(uint256 j=wi; j<stride; ++j){
            forward_table[j] = vi;
        }
        uint256 offset = 0;
        for(uint256 i=1; i<len; ++i){
            offset += stride;
            wi = amounts[i];
            vi = values[i];
             
            for(uint256 j; j<wi; ++j){
                forward_table[offset+j] = forward_table[offset-stride+j];                 
            }
            for(uint256 j=wi; j<stride; ++j){
                uint256 value_without = forward_table[offset-stride+j];
                uint256 value_with = forward_table[offset-stride+j-wi] + vi;
                forward_table[offset+j] = value_with > value_without ? value_with : value_without;                 
            }
        }
        uint256[] memory backward_table = new uint256[](len*stride);
        wi = amounts[len-1];
        vi = values[len-1];
        for(uint256 j=wi; j<stride; ++j){
            backward_table[offset+j] = vi;
        }
        for(uint256 i=len-2; ; --i){
            offset -= stride;
            wi = amounts[i];
            vi = values[i];


            for(uint256 j; j<wi; ++j){
                backward_table[offset+j] = backward_table[offset+stride+j];                 
            }
            for(uint256 j=wi; j<stride; ++j){
                uint256 value_without = backward_table[offset+stride+j];
                uint256 value_with = backward_table[offset+stride+j-wi] + vi;
                backward_table[offset+j] = value_with > value_without ? value_with : value_without;                 
            }
            if (i==0)
                break;
        }
        offset = (len-1)*stride;
        uint256 remainingAmount = stride - 1;
        uint256 optval = forward_table[offset+remainingAmount];
        if (forward_table[offset+remainingAmount] != forward_table[offset-stride+remainingAmount])
        {
            uint88 payment = uint88(forward_table[offset - 1] - (optval - values[len - 1]));
            address bidder = bidders[len - 1];
            if (uint160(bidder) > type(uint8).max) {
                withdrawableBalance += payment;
            }
            outcomes[bidder] = Outcome({payment: payment, amount: amounts[len - 1]});
            //payment[bidders[len-1]] = forward_table[offset-1] - (optval - values[len-1]);
            remainingAmount -= amounts[len-1];
        }
        for(uint256 i=len-2; i>0; --i)
        {
            offset -= stride;
            wi = amounts[i];
            if (forward_table[offset+remainingAmount] != forward_table[offset-stride+remainingAmount])
            {
                //remainingAmount -= wi;
                uint256 M = 0;
                for(uint256 j; j<stride; ++j)
                {
                    uint256 m = forward_table[offset-j-1]+backward_table[offset+stride+j];
                    if (m > M)
                        M = m;
                }
                uint88 payment = uint88(M - (optval - values[i]));
                address bidder = bidders[i];
                if (uint160(bidder) > type(uint8).max) {
                    withdrawableBalance += payment;
                }
                outcomes[bidder] = Outcome({payment: payment, amount: amounts[i]});
                remainingAmount -= amounts[i];
                //payment[bidders[i]] = M - (optval - values[i]);
            }
        }
        if (forward_table[remainingAmount] > 0)
        {
            uint88 payment = uint88(backward_table[2 * stride - 1] - (optval - values[0]));
            address bidder = bidders[0];
            if (uint160(bidder) > type(uint8).max) {
                withdrawableBalance += payment;
            }
            outcomes[bidder] = Outcome({payment: payment, amount: amounts[0]});
            remainingAmount -= amounts[0];

            //remainingAmount -= amounts[0];
            //payment[bidders[0]] = backward_table[2*stride-1] - (optval - values[0]);
        }
        //for(uint256 i; i< len; ++i)
        //{
        //    console.log(i, payment[bidders[i]]);
        //}
    }


    /// @notice vcg
    /// TODO: need to keep track of all the payments so owner can withdraw the correct amount
    function vcg() internal {
        uint256 len = revealedBids.length < topBidders ? revealedBids.length : topBidders;
        uint256[] memory values = new uint256[](len);
        uint8[] memory amounts = new uint8[](len);
        address[] memory bidders = new address[](len);
        uint8 stride = collectionSize + 1;
        for (uint256 i; i < len; ++i) {
            RevealedBid memory r = revealedBids[i];
            bidders[i] = r.bidder;
            values[i] = r.value;
            amounts[i] = r.amount;
        }
        uint256[] memory forward = new uint256[](len*stride);
        uint8 wi = amounts[0];
        uint256 vi = values[0];
        for (uint256 j = wi; j < stride; ++j) {
            forward[j] = vi;
        }
        uint256 previousRowOffset = 0;
        uint256 currentRowOffset = stride;
        for (uint256 i = 1; i < len; ++i) {
            wi = amounts[i];
            vi = values[i];

            for (uint256 j; j < wi; ++j) {
                forward[currentRowOffset + j] = forward[previousRowOffset + j];
            }
            for (uint256 j = wi; j < stride; ++j) {
                uint256 valueWithout = forward[previousRowOffset + j];
                uint256 valueWith = forward[previousRowOffset + j - wi] + vi;
                forward[currentRowOffset + j] = valueWith > valueWithout ? valueWith : valueWithout;
            }
            previousRowOffset += stride;
            currentRowOffset += stride;
        }
        // offset used to be the current row so it is pointing to len-1 row
        // currentRowOffSet is pointing to len (outside memory)

        uint256[] memory backward = new uint256[](len*stride);
        wi = amounts[len - 1];
        vi = values[len - 1];
        for (uint256 j = wi; j < stride; ++j) {
            backward[previousRowOffset + j] = vi;
        }
        currentRowOffset -= (stride << 1);

        for (uint256 i = len - 2;; --i) {
            wi = amounts[i];
            vi = values[i];

            for (uint256 j; j < wi; ++j) {
                backward[currentRowOffset + j] = backward[previousRowOffset + j];
            }
            for (uint256 j = wi; j < stride; ++j) {
                uint256 valueWithout = backward[previousRowOffset + j];
                uint256 valueWith = backward[previousRowOffset + j - wi] + vi;
                backward[currentRowOffset + j] = valueWith > valueWithout ? valueWith : valueWithout;
            }
            if (i == 0) {
                break;
            }
            previousRowOffset -= stride;
            currentRowOffset -= stride;
        }
        currentRowOffset = (len - 1) * stride;
        previousRowOffset = currentRowOffset - stride;
        uint256 remainingAmount = stride - 1;
        uint256 optval = forward[currentRowOffset + remainingAmount];
        if (forward[currentRowOffset + remainingAmount] != forward[previousRowOffset + remainingAmount]) {
            uint88 payment = uint88(forward[currentRowOffset - 1] - (optval - values[len - 1]));
            address bidder = bidders[len - 1];
            if (uint160(bidder) > type(uint8).max) {
                withdrawableBalance += payment;
            }
            outcomes[bidder] = Outcome({payment: payment, amount: amounts[len - 1]});
            //console.log("o", bidder, outcomes[bidder].payment, outcomes[bidder].amount);
            remainingAmount -= amounts[len - 1];
        }
        for (uint256 i = len - 2; i > 0; --i) {
            currentRowOffset -= stride;
            previousRowOffset -= stride;
            if (forward[currentRowOffset + remainingAmount] != forward[previousRowOffset + remainingAmount]) {
                uint256 nextRowOffset = currentRowOffset + stride;
                uint256 previousRowLast = currentRowOffset - 1;
                uint256 M = 0;
                for (uint256 j; j < stride; ++j) {
                    uint256 m = forward[previousRowLast - j] + backward[nextRowOffset + j];
                    M = m > M ? m : M;
                }
                uint88 payment = uint88(M - (optval - values[i]));
                address bidder = bidders[i];
                if (uint160(bidder) > type(uint8).max) {
                    withdrawableBalance += payment;
                }
                outcomes[bidder] = Outcome({payment: payment, amount: amounts[i]});
                //console.log("o", bidder, outcomes[bidder].payment, outcomes[bidder].amount);
                remainingAmount -= amounts[i];
            }
        }
        if (forward[remainingAmount] > 0) {
            uint88 payment = uint88(backward[2 * stride - 1] - (optval - values[0]));
            address bidder = bidders[0];
            if (uint160(bidder) > type(uint8).max) {
                withdrawableBalance += payment;
            }
            outcomes[bidder] = Outcome({payment: payment, amount: amounts[0]});
            //console.log("o", bidder, outcomes[bidder].payment, outcomes[bidder].amount);
            remainingAmount -= amounts[0];
        }
        //        for(uint256 i; i< len; ++i)
        //        {
        //            console.log(i, payments[bidders[i]]);
        //        }
    }

    function mint() external nonReentrant {
        if (auction.status != Status.Finalized) {
            revert AuctionNotFinalizedError();
        }

        Outcome memory outcome = outcomes[msg.sender];
        uint8 amount = outcome.amount;
        for (uint8 i = 0; i < amount; ++i) {
            uint8 newTokenId = currentTokenId++;
            if (newTokenId > collectionSize) {
                revert TotalSupplyExceeded();
            } // could only happen if there's a bug in vcg
            _safeMint(msg.sender, newTokenId);
        }
    }

    function withdrawBalance() external onlyOwner {
        uint248 amount = withdrawableBalance;
        withdrawableBalance = 0;
        msg.sender.safeTransferETH(amount);
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, tokenId.toString())) : "";
    }

    /*
    # Restore the heap invariant assuming 'revealedBids' is a heap except possibly for pos.
    */
    function siftDown(uint256 pos) internal {
        RevealedBid memory newItem = revealedBids[pos];
        /*     
        # Follow the path to the root, moving parents down until finding a place newItem fits.
        */
        while (pos > 0) {
            uint256 parentpos = (pos - 1) >> 1;
            RevealedBid memory parent = revealedBids[parentpos];
            if (newItem.value * parent.amount < parent.value * newItem.amount) {
                revealedBids[pos] = parent;
                pos = parentpos;
                continue;
            }
            break;
        }
        revealedBids[pos] = newItem;
    }

    function siftUp() internal {
        uint256 endpos = topBidders;
        uint256 pos = 0;
        RevealedBid memory newItem = revealedBids[pos];
        uint256 leftpos = (pos << 1) + 1;
        while (leftpos < endpos) {
            uint256 rightpos = leftpos + 1;
            RevealedBid memory left = revealedBids[leftpos];
            RevealedBid memory right = revealedBids[rightpos];
            if (left.value * right.amount < right.value * left.amount) {
                revealedBids[pos] = left;
                pos = leftpos;
            } else {
                revealedBids[pos] = right;
                pos = rightpos;
            }
            leftpos = (pos << 1) + 1;
        }
        /*     
        # The leaf at pos is empty now.  Put newItem there, and bubble it up 
        # to its final resting place (by sifting its parents down).
        */
        revealedBids[pos] = newItem;
        siftDown(pos);
    }
}
