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
    /// @param payment Payment as determined by the VCG auction.
    /// @param amount Amount of items awarded.
    struct Outcome {
        uint88 payment;
        uint8 amount;
    }

    AuctionInfo public auction;
    address paymentData;
    // ====
    address topRevealedBids;
    uint88 public withdrawableBalance;
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
        if ((_topBidders & 1) == 0) {
            revert TopBiddersOddError();
        }
        name = _name;
        symbol = _symbol;
        collectionSize = _size;
        topBidders = _topBidders;
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
    function createAuction(uint32 startTime, uint32 bidPeriod, uint32 revealPeriod, uint88 reservePrice)
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
    ///        `bytes21(keccak256(abi.encode(nonce, bidValue, bidAmount, address(this))))`.
    function commitBid(bytes21 commitment) external payable {
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
        if (bid.collateral < theAuction.reservePrice) {
            revert CollateralLessThanReservePriceError();
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
        if (
            collateral < bidValue || bidValue < theAuction.reservePrice * bidAmount || bidAmount > collectionSize
                || bidAmount == 0
        ) {
            // Return collateral in any of the following cases
            // - undercollateralized bid
            // - bid price below reserve price
            // - bid amount is 0 or greater than the collection size
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            addRevealedBid(msg.sender, bidAmount, bidValue);
            emit BidRevealed(msg.sender, bidValue, bidAmount);
        }
    }

    /// @notice Adds a bid to the revealedBids heap. Rearranges revealedBids to maintain heap invariant among topBidders.
    /// @param account The account submitting the bid.
    /// @param bidAmount The amount of the bid.
    /// @param bidValue The value of the bid.
    function addRevealedBid(address account, uint8 bidAmount, uint88 bidValue) internal {
        RevealedBid memory newBid = RevealedBid({bidder: account, amount: bidAmount, value: bidValue});

        if (revealedBids.length < topBidders) {
            revealedBids.push(newBid);
            siftDown(revealedBids.length - 1);
        } else {
            // we have reached capacity
            // check whether this bid has a higher price than the smallest price in topBidders
            // if so move it in the heap of topBidders otherwise just append it
            RevealedBid memory popCandidate = revealedBids[0];
            if (uint256(bidValue) * uint256(popCandidate.amount) > uint256(popCandidate.value) * uint256(bidAmount)) {
                revealedBids.push(popCandidate);
                revealedBids[0] = newBid;
                siftUp();
            } else {
                revealedBids.push(newBid);
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
        bid.commitment = bytes21(0);
    }

    /// @notice Withdraws collateral. If msg.sender has to pay for any NFTs, the payment is subtracted.
    function withdrawCollateral() external nonReentrant {
        AuctionInfo memory theAuction = auction;
        SealedBid storage bid = sealedBids[msg.sender];
        if (bid.commitment != bytes21(0)) {
            revert UnrevealedBidError();
        }
        if (theAuction.status == Status.Ongoing) {
            revert AuctionNotFinalizedError();
        }
        uint88 refund = bid.collateral;
        // Return remainder
        if (refund > 0) {
            refund -= outcomes[msg.sender].payment;
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
    }

    /// @dev Allocates an array without initializing the memory. Saves a bit of gas compared to new.
    function allocateRaw(uint256 n) internal pure returns (uint256[] memory array) {
        // Allocate the array in memory by advancing the free memory pointer by 32 * (n + 1) bytes
        assembly {
            array := mload(64) // Assign the array variable to the start of the array
            mstore(array, n) // Store the length of the array in the first 32 bytes of the array
            mstore(64, add(array, add(shl(5, n), 32))) // Advance the free memory pointer by 32 * n + 32 bytes
        }
    }

    /// @dev Wrapper around sstore2.write that works with uint256 arrays instead of bytes
    function storeUintArrayAsBytes(uint256[] memory input) internal returns (address) {
        uint256 n = input.length;
        bytes memory buf;
        assembly {
            buf := input
            mstore(buf, mul(32, n))
        }
        return SSTORE2.write(buf);
    }

    /// @dev Wrapper around sstore2.read that works with uint256 arrays instead of bytes
    function loadBytesAsUintArray(address pointer) internal view returns (uint256[] memory output) {
        bytes memory input = SSTORE2.read(pointer);
        uint256 n = input.length / 32;
        assembly {
            output := input
            mstore(output, n)
        }
    }

    /// @dev copy the top revealedBids from storage to contract code (using sstore2) so the rest of the auction steps are cheaper.
    function storeTopRevealedBids() internal {
        uint256 len = revealedBids.length < topBidders ? revealedBids.length : topBidders;
        uint256[] memory top = allocateRaw(len);
        uint256 slot;
        uint256 rbData;
        assembly {
            slot := revealedBids.slot
        }
        slot = uint256(keccak256(abi.encode(slot)));
        for (uint256 i = 0; i < len; i++) {
            assembly {
                rbData := sload(add(slot, i))
            }
            top[i] = rbData;
        }
        topRevealedBids = storeUintArrayAsBytes(top);
    }

    /// @dev Implementation of Step A of auction finalization.
    ///      Add dummy bidders at the reserve price and copy the top bids so they can be read cheaply in the next step.
    function finalizeAuctionStepAimpl() internal {
        AuctionInfo memory theAuction = auction;

        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }

        // add dummy buyers at the reserve price
        for (uint8 i = 128; i > 0; i >>= 1) {
            if (i <= collectionSize) {
                addRevealedBid(address(uint160(i)), i, i * theAuction.reservePrice);
            }
        }
        storeTopRevealedBids();
    }

    /// @notice Step A of auction finalization.
    ///         Add dummy bidders at the reserve price and copy the top bids so they can be read cheaply in the next step.
    function finalizeAuctionStepA() external onlyOwner {
        finalizeAuctionStepAimpl();
    }

    /// @notice Step B of auction finalization. Runs the VCG auction and writes the results in paymentData.
    function finalizeAuctionStepB() external onlyOwner {
        if (topRevealedBids == address(0)) {
            revert StepASkippedError();
        }
        if (paymentData != address(0)) {
            revert StepAlreadyExecutedError();
        }
        vcg();
    }

    /// @dev Implementation of Step C of auction finalization.
    ///      Writes the payment data nicely in a mapping and computes the total payment for the owner.
    function finalizeAuctionStepCimpl() internal {
        uint256[] memory p = loadBytesAsUintArray(paymentData);
        uint256 winners = p.length;
        uint256 totalPayments = 0;
        for (uint256 i = 0; i < winners; ++i) {
            uint256 pData = p[i];
            address bidder = address(uint160(pData & 0x00ffffffffffffffffffffffffffffffffffffffff));
            uint8 amount = uint8((pData >> 160) & 255);
            uint88 payment = uint88(pData >> 168);
            totalPayments += payment;
            outcomes[bidder] = Outcome({payment: payment, amount: amount});
        }
        withdrawableBalance = uint88(totalPayments);
        auction.status = Status.Finalized;
    }

    /// @notice Step C of auction finalization.
    ///         Writes the payment data nicely in a mapping and computes the total payment for the owner.
    function finalizeAuctionStepC() external onlyOwner {
        if (topRevealedBids == address(0)) {
            revert StepASkippedError();
        }
        if (paymentData == address(0)) {
            revert StepBSkippedError();
        }
        if (withdrawableBalance > 0) {
            revert StepAlreadyExecutedError();
        }
        finalizeAuctionStepCimpl();
    }

    /// @notice Finalizes the auction by computing the winners and their payments.
    function finalizeAuction() external onlyOwner {
        finalizeAuctionStepAimpl();
        vcg();
        finalizeAuctionStepCimpl();
    }

    /// @dev fills the dynamic programming table for a knapsack problem in the forward direction
    ///      that is by considering the bidders in order 0, 1, ..., rb.length
    ///      Element forward[i][j] (aka forward[i * stride + j]) stores the best value
    ///      we can get when considering bidders {0,1,...,i} and assuming the collection size is j NFTs
    ///      The value forward[rb.length - 1, collectionSize] will contain the optimal value
    ///      This table will then be used to determine the winners and their payments
    /// @param rb an array of packed RevealedBid data stored as [ value | amount | bidder ]
    function forwardFill(uint256[] memory rb) internal view returns (uint256[] memory forward) {
        uint256 len = rb.length;
        uint256 stride = collectionSize + 1;
        // Every position in the table will be written so we do not need to initialize with 0
        forward = allocateRaw(len * stride);

        assembly {
            // all pointer arithmetic will be done with multiples of 32 so we compute it once for stride
            stride := shl(5, stride)
            // Pointer to the revealed bid data
            let rbPtr := add(rb, 32)
            // rbData will be holding values we read from rb
            let rbData := mload(rbPtr) // low bits to hi bits [vi | wi | bidder]
            // We shift the amount by 5 because we will be adding it as offset to indices in the table
            let wi := shl(5, and(shr(160, rbData), 255)) // wi = ((rbData >> 160) & 255) << 5
            // bid value
            let vi := shr(168, rbData) //vi = rbData >> 168
            // curPtr will be used to write the entry i,j
            let curPtr := add(forward, 32)
            // the first wi entries in row i are treated differently that the rest
            let breakpoint := add(curPtr, wi)
            // endPtr is where the i-th row ends
            let endPtr := add(curPtr, stride)

            // for the first wi entries we can't do anything so the best value is 0
            for {} lt(curPtr, breakpoint) { curPtr := add(curPtr, 32) } { mstore(curPtr, 0) }
            // for the rest of the items in the first row the best value is vi
            for {} lt(curPtr, endPtr) { curPtr := add(curPtr, 32) } { mstore(curPtr, vi) }
            // for the i-th row
            for { let i := 1 } lt(i, len) { i := add(i, 1) } {
                // read the data from the i-th bidder
                rbPtr := add(rbPtr, 32)
                rbData := mload(rbPtr)
                wi := shl(5, and(shr(160, rbData), 255))
                vi := shr(168, rbData)
                breakpoint := add(curPtr, wi)
                endPtr := add(curPtr, stride)
                // for the first wi entries the best we can do is take the solution from previous row
                for {} lt(curPtr, breakpoint) { curPtr := add(curPtr, 32) } {
                    mstore(curPtr, mload(sub(curPtr, stride)))
                }
                // for the rest of the items we consider taking the ith bidder or not taking him/her
                for {} lt(curPtr, endPtr) { curPtr := add(curPtr, 32) } {
                    let prv := sub(curPtr, stride)
                    // if we take him/her we have vi plus the best with bidders 0, ..., i-1 up to the current budget minus wi
                    let valueWith := add(vi, mload(sub(prv, wi)))
                    // if we don't take him/her we have whatever was best with bidders 0, ..., i-1 up to the current budget
                    let valueWithout := mload(prv)
                    // we choose the best of these two options
                    switch gt(valueWith, valueWithout)
                    case 0 { mstore(curPtr, valueWithout) }
                    default { mstore(curPtr, valueWith) }
                }
            }
        }
        return forward;
    }

    /// @dev runs a VCG auction
    function vcg() internal {
        unchecked {
            //yolo
            // load the data
            uint256[] memory rb = loadBytesAsUintArray(topRevealedBids);
            // fill the dynamic programming table
            uint256[] memory forward = forwardFill(rb);
            uint256 len = rb.length;
            uint256 stride = collectionSize + 1;
            // the optimum value will be used for determining the payments
            uint256 optval = forward[len * stride - 1];

            // the payments are determined by considering the difference between two values
            // the (counterfactual) value we would get if we excluded the i-th bidder minus
            // the value we get from all other bidders in the optimal solution.
            // If vi is the value of the i-th bidder then the latter is optval - vi.
            // For the former we could solve the knapsack problem with each bidder excluded but
            // that would be unnecessarily expensive. Instead, as alluded by the forwardFill
            // name, we can construct a backward table where element[i][j] (aka backard[i * stride + j])
            // holds the best value when considering bidders {len-1, len-2,...,i} and assuming the
            // collection size is collectionSize minus j NFTs. Then we have that the optimal value
            // with bidder i excluded is max_k forward[i-1][k] + backward[i+1][k].
            // In the code below we do not actually store the whole backward table but instead we
            // compute it as we go backwards using just two buffers curr and prev holding the i-th
            // and (i+1)-th rows of backward respectively.
            uint256[] memory curr = allocateRaw(stride);
            uint256[] memory prev = allocateRaw(stride);
            // We write the winners and their payments in output
            uint256[] memory output = allocateRaw(len);

            /// @solidity memory-safe-assembly
            assembly {
                // multiply stride with 32 once and for all
                stride := shl(5, stride)
                // start processing revealed bid data from the back
                let rbPtr := add(rb, shl(5, len))
                let rbData := mload(rbPtr)
                let bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                // wi is used for indexing so we multiply by 32
                let wi := shl(5, and(shr(160, rbData), 255))
                let vi := shr(168, rbData)

                let curPtr := add(curr, 32)
                let prevPtr := add(prev, 32)
                let endPtr := sub(add(prevPtr, stride), wi)
                // similarly to forwardFill when considering the last bidder the best we can do is either wi or 0
                for {} lt(prevPtr, endPtr) { prevPtr := add(prevPtr, 32) } { mstore(prevPtr, vi) }
                endPtr := add(endPtr, wi)
                for {} lt(prevPtr, endPtr) { prevPtr := add(prevPtr, 32) } { mstore(prevPtr, 0) }
                // now we start determining winners and computing payments in one big loop backwards through the forward array
                prevPtr := add(prev, 32)
                let outputPtr := add(output, 32)
                // fwdPtr will be used for backtracing through forward to determine winners
                let fwdPtr := add(forward, mul(stride, len))
                let valueWithoutLast := mload(sub(fwdPtr, stride))
                // the last bidder is a winner if the value without him/her is different that the value with him/her
                if iszero(eq(mload(fwdPtr), valueWithoutLast)) {
                    // dummy bidders may exist and are coded as addresses whose value is <= 128
                    // if you have such an address congratulations
                    if iszero(lt(bidder, 129)) {
                        let payment := sub(valueWithoutLast, sub(optval, vi))
                        mstore(
                            outputPtr, or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff))
                        )
                        outputPtr := add(outputPtr, 32)
                    }
                    // when the last bidder is a winner the rest of the winners can be determined by looking at the subproblem with wi fewer NFTs
                    fwdPtr := sub(fwdPtr, wi)
                }
                // prevRowPtr holds the address of the start of the i-1 row in the forward table
                for { let prevRowPtr := add(forward, add(32, mul(stride, sub(len, 3)))) } gt(prevRowPtr, forward) {
                    prevRowPtr := sub(prevRowPtr, stride)
                } {
                    // prevPtr points to the (conceptual) i+1 row of the backward table
                    prevPtr := add(prev, 32)
                    // we move fwdPtr from the i+1 row to the ith row
                    fwdPtr := sub(fwdPtr, stride)
                    // we iterate backwards through the revealed bids
                    rbPtr := sub(rbPtr, 32)
                    rbData := mload(rbPtr)
                    wi := shl(5, and(shr(160, rbData), 255))
                    vi := shr(168, rbData)
                    // if the ith bidder is a winner
                    if iszero(eq(mload(fwdPtr), mload(sub(fwdPtr, stride)))) {
                        bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                        // if the ith bidder is not a dummy bidder
                        if iszero(lt(bidder, 129)) {
                            // compute bestWithoutBidder = max_k forward[i-1][k] + backward[i+1][k]
                            let bestWithoutBidder := 0
                            let localFwdPtr := prevRowPtr
                            let localBwdPtr := prevPtr
                            endPtr := add(localFwdPtr, stride)
                            for {} lt(localFwdPtr, endPtr) {
                                localFwdPtr := add(localFwdPtr, 32)
                                localBwdPtr := add(localBwdPtr, 32)
                            } {
                                let m := add(mload(localFwdPtr), mload(localBwdPtr))
                                switch gt(bestWithoutBidder, m)
                                case 0 { bestWithoutBidder := m }
                            }
                            // compute payment
                            let payment := sub(bestWithoutBidder, sub(optval, vi))
                            // store payment data
                            mstore(
                                outputPtr,
                                or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff))
                            )
                            outputPtr := add(outputPtr, 32)
                        }
                        // when the ith bidder is a winner the rest of the winners can be determined by looking at the subproblem with wi fewer NFTs
                        fwdPtr := sub(fwdPtr, wi)
                    }
                    // compute the i-th row for the backward table
                    curPtr := add(curr, 32)
                    endPtr := sub(add(curPtr, stride), wi)
                    // when the budget is large enough we take the best of including and excluding the ith bidder
                    for {} lt(curPtr, endPtr) {
                        curPtr := add(curPtr, 32)
                        prevPtr := add(prevPtr, 32)
                    } {
                        let valueWithout := mload(prevPtr)
                        let valueWith := add(vi, mload(add(prevPtr, wi)))
                        switch gt(valueWith, valueWithout)
                        case 0 { mstore(curPtr, valueWithout) }
                        default { mstore(curPtr, valueWith) }
                    }
                    endPtr := add(endPtr, wi)
                    // when the budget is small we copy from the previous row
                    for {} lt(curPtr, endPtr) {
                        curPtr := add(curPtr, 32)
                        prevPtr := add(prevPtr, 32)
                    } { mstore(curPtr, mload(prevPtr)) }
                    // finally we swap the roles of curr and prev
                    let tmp := prev
                    prev := curr
                    curr := tmp
                }
                // we handle the first bidder separately since we do not need to search for bestWithBidder
                // that would be stored on backward[1,0] similarly to how the best without the last bidder
                // is stored in forward[len-2, collectionSize]
                fwdPtr := sub(fwdPtr, stride)
                if gt(mload(fwdPtr), 0) {
                    rbPtr := sub(rbPtr, 32)
                    rbData := mload(rbPtr)
                    bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                    wi := shl(5, and(shr(160, rbData), 255))
                    if iszero(lt(bidder, 129)) {
                        vi := shr(168, rbData)
                        let payment := sub(mload(add(prev, 32)), sub(optval, vi))
                        rbData := or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff))
                        mstore(outputPtr, rbData)
                        outputPtr := add(outputPtr, 32)
                    }
                    fwdPtr := sub(fwdPtr, wi)
                }
                // adjust the length of output to reflect the actual number of winners
                mstore(output, shr(5, sub(outputPtr, add(output, 32))))
            }
            // use sstore2.write to write the output making the next step cheaper.
            paymentData = storeUintArrayAsBytes(output);
        }
    }

    /// @notice Mints any NFTs that were awarded to msg.sender during the auction
    function mint() external nonReentrant {
        if (auction.status != Status.Finalized) {
            revert AuctionNotFinalizedError();
        }

        Outcome storage outcome = outcomes[msg.sender];
        uint8 current = currentTokenId;
        uint8 end = current + outcome.amount;
        if (current < end) {
            outcome.amount = 0;
            for (; current < end; ++current) {
                // This check is a bit of an overkill since the auction should guarrantee it
                if (current > collectionSize) {
                    revert TotalSupplyExceeded();
                }
                _safeMint(msg.sender, current);
            }
            currentTokenId = end;
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
            if (newItem.value * parent.amount < parent.value * newItem.amount) {
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
        // The leaf at pos is empty now.  Put newItem there, and bubble it up to its final resting place (by sifting its parents down).
        revealedBids[pos] = newItem;
        siftDown(pos);
    }
}
