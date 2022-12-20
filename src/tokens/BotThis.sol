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
        if (bid.collateral < theAuction.reservePrice)
            revert CollateralLessThanReservePriceError();
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
        if (collateral < bidValue || bidValue < theAuction.reservePrice || bidAmount > collectionSize || bidAmount == 0) {
            // Return collateral in any of the following cases
            // - undercollateralized bid
            // - bid below reserve price
            // - bid amount is 0 or greater than the collection size
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
        uint88 refund = bid.collateral;
        // Return remainder
        if (refund > 0)
        {
            refund -= outcomes[msg.sender].payment;
            bid.collateral = 0;
            msg.sender.safeTransferETH(refund);
        }
    }

    function cancelAuction() external onlyOwner {
        AuctionInfo memory theAuction = auction;
        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }
        auction.status = Status.Canceled;
    }

    /// @notice Finalizes the auction. Can only do so if the bid reveal
    ///         phase is over.
    function finalizeAuctionGood() external onlyOwner {
        AuctionInfo memory theAuction = auction;

        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }

        // add dummy buyers at the reserve price
        for (uint8 i = 128; i > 0; i >>= 1) {
            if (i <= collectionSize)
                addRevealedBid(address(uint160(i)), i, i * theAuction.reservePrice);
        }

        auction.status = Status.Finalized;

        vcggood();
    }


    /// @notice Finalizes the auction. Can only do so if the bid reveal
    ///         phase is over.
    function finalizeAuction1impl() internal {
        AuctionInfo memory theAuction = auction;

        if (theAuction.startTime == 0 || block.timestamp <= theAuction.endOfRevealPeriod) {
            revert WaitUntilAfterRevealError();
        }

        // add dummy buyers at the reserve price
        for (uint8 i = 128; i > 0; i >>= 1) {
            if (i <= collectionSize)
                addRevealedBid(address(uint160(i)), i, i * theAuction.reservePrice);
        }
        auction.status = Status.Finalized;
        saveTopRevealedBidsArray();
    }

    function finalizeAuction1() external onlyOwner {
        finalizeAuction1impl();    
    }

    function storeUintArrayAsBytes(uint256[] memory input) internal returns (address)
    {
        uint n = input.length;
        bytes memory buf;
        assembly {
            buf := input
            mstore(buf, mul(32, n))
        }
        return SSTORE2.write(buf);
    }

    function loadBytesAsUintArray(address pointer) internal view returns (uint256[] memory output) {
        bytes memory input = SSTORE2.read(pointer);
        uint256 n = input.length / 32;
        assembly {
            output := input
            mstore(output, n)
        }
    }

    function saveTopRevealedBidsArray() internal
    {
        uint256 len = revealedBids.length < topBidders ? revealedBids.length : topBidders;
        uint256[] memory top = allocateRaw(len);
        uint256 slot;
        uint256 rbData;
        assembly {
            slot := revealedBids.slot
        }
        slot = uint256(keccak256(abi.encode(slot)));
        for (uint i=0; i<len; i++){
            assembly{
                rbData := sload(add(slot, i))
            }
            top[i] = rbData;
        }
        topRevealedBids = storeUintArrayAsBytes(top);
    }
    
    /// @notice Finalizes the auction. Can only do so if the bid reveal
    ///         phase is over.
    function finalizeAuction2() external onlyOwner {
        // TODO ensure finalizeAuction1 has been run
        vcgnew();
    }

    /// @notice Finalizes the auction. Can only do so if the bid reveal
    ///         phase is over.
    function finalizeAuction3impl() internal {
        // TODO ensure finalizeAuction2 has been run
        uint256[] memory p = loadBytesAsUintArray(paymentData);
        uint256 winners = p.length;
        uint256 totalPayments = 0;
        for(uint256 i=0; i < winners; ++i)
        {
            uint256 pData = p[i];
            address bidder = address(uint160(pData & 0x00ffffffffffffffffffffffffffffffffffffffff));
            uint8 amount = uint8((pData>>160) & 255);
            uint88 payment = uint88(pData >> 168);
            totalPayments += payment; 
            outcomes[bidder] = Outcome({payment: payment, amount: amount});
        }
        withdrawableBalance = uint88(totalPayments);
    }

    function finalizeAuction3() external onlyOwner {
        finalizeAuction3impl();
    }

    function finalizeAuction() external onlyOwner {
        finalizeAuction1impl();
        vcgnew();
        finalizeAuction3impl();
    }

    /// @notice vcggood
    function vcggood() internal
    {
        unchecked{
            uint256 totalPayments = 0;
            uint256 len = revealedBids.length < topBidders ? revealedBids.length : topBidders;
            uint256[] memory values = new uint256[](len);
            uint256[] memory amounts = new uint256[](len);
            address[] memory bidders = new address[](len);
            uint256 stride = collectionSize + 1;
            for (uint256 i; i<len; ++i){
                RevealedBid memory rbi = revealedBids[i];
                bidders[i] = rbi.bidder;
                values[i] = rbi.value;
                amounts[i] = rbi.amount;
            }
            uint256[] memory forward_table = new uint256[](len*stride);

            uint256 wi = amounts[0];
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
                uint256 payment = forward_table[offset - 1] - (optval - values[len - 1]);
                address bidder = bidders[len - 1];
                if (uint160(bidder) > type(uint8).max) {
                    totalPayments += payment;
                }
                outcomes[bidder] = Outcome({payment: uint88(payment), amount: uint8(amounts[len - 1])});
                remainingAmount -= amounts[len-1];
            }
            for(uint256 i=len-2; i>0; --i)
            {
                offset -= stride;

                if (forward_table[offset+remainingAmount] != forward_table[offset-stride+remainingAmount])
                {
                    wi = amounts[i];
                    uint256 M = 0;
                    for(uint256 j; j<stride; ++j)
                    {
                        uint256 m = forward_table[offset-j-1]+backward_table[offset+stride+j];
                        M = m > M ? m : M;
                    }
                    uint256 payment = M - (optval - values[i]);
                    address bidder = bidders[i];
                    if (uint160(bidder) > type(uint8).max) {
                        totalPayments += payment;
                    }
                    outcomes[bidder] = Outcome({payment: uint88(payment), amount: uint8(wi)});
                    remainingAmount -= wi;
                }
            }
            if (forward_table[remainingAmount] > 0)
            {
                wi = amounts[0];
                uint256 payment = backward_table[2 * stride - 1] - (optval - values[0]);
                address bidder = bidders[0];
                if (uint160(bidder) > type(uint8).max) {
                    totalPayments += payment;
                }
                outcomes[bidder] = Outcome({payment: uint88(payment), amount: uint8(wi)});
                remainingAmount -= wi;
            }
            withdrawableBalance = uint88(totalPayments);
        }
    }

    function allocateRaw(uint256 n) internal pure returns (uint256[] memory array) {
        // Allocate the array in memory by advancing the free memory pointer
        // by 32 * (n + 1) bytes (32 bytes per uint256 value)
        assembly {
            array := mload(64) // Assign the array variable to the start of the array
            mstore(array, n)   // Store the length of the array in the first 32 bytes of the array
            mstore(64, add(array, add(shl(5, n), 32))) // Advance the free memory pointer by 32 * n + 32 bytes
        }
    }

    //function loadTopRevealedBidArray() internal view returns (uint256[] memory output) {
    //    return loadBytesAsUintArray(topRevealedBids);
    //}

    function forwardFill(uint256[] memory rb) internal view returns (uint256[] memory forward)
    {
        uint256 len = rb.length;
        uint256 stride = collectionSize + 1;
        forward = allocateRaw(len*stride); 

        assembly {
            stride := shl(5, stride)
            let rbPtr := add(rb, 32)
            let rbData := mload(rbPtr) // low bits to hi bits [vi | wi | bidder]
            let wi := shl(5, and(shr(160, rbData), 255)) // wi = ((rbData >> 160) & 255) << 5
            let vi := shr(168, rbData) //vi = rbData >> 168 
            let curPtr := add(forward, 32) 
            let breakpoint := add(curPtr, wi)
            let endPtr := add(curPtr, stride)

            for { } lt(curPtr, breakpoint) { curPtr := add(curPtr, 32) }
            {
                mstore(curPtr, 0)
            } 

            for { } lt(curPtr, endPtr) { curPtr := add(curPtr, 32) }
            {
                mstore(curPtr, vi)
            } 
            
            for { let i := 1 } lt(i, len) { i := add(i, 1) }
            {
                rbPtr := add(rbPtr, 32)
                rbData := mload(rbPtr)
                wi := shl(5, and(shr(160, rbData), 255))
                vi := shr(168, rbData)
                breakpoint := add(curPtr, wi)
                endPtr := add(curPtr, stride)
                for { } lt(curPtr, breakpoint) { curPtr := add(curPtr, 32) }
                {
                    mstore(curPtr ,  mload(sub(curPtr,stride)))
                } 

                for { } lt(curPtr, endPtr) { curPtr := add(curPtr, 32) }
                {
                    let prv := sub(curPtr,stride)
                    let valueWith := add(vi, mload(sub(prv, wi)))
                    let valueWithout := mload(prv)
                    switch gt(valueWith, valueWithout)
                    case 0 { mstore(curPtr, valueWithout) }
                    default { mstore(curPtr, valueWith) }
                } 
            } 
        }
        return forward;
    }

    /// @notice vcgnew
    function vcgnew() internal 
    {
        unchecked{
            uint256[] memory rb = loadBytesAsUintArray(topRevealedBids);
            uint256[] memory forward = forwardFill(rb);
            uint256 len = rb.length;
            uint256 stride = collectionSize + 1;
            uint256 optval = forward[len * stride - 1];
            uint256[] memory curr = allocateRaw(stride);
            uint256[] memory prev = allocateRaw(stride);
            uint256[] memory out = allocateRaw(len);

            /// @solidity memory-safe-assembly
            assembly
            {
                stride := shl(5, stride)
                let rbPtr := add(rb, shl(5, len))
                let rbData := mload(rbPtr)
                let bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                let wi := shl(5, and(shr(160, rbData), 255))
                let vi := shr(168, rbData)

                let curPtr := add(curr, 32)
                let prevPtr := add(prev, 32)
                let endPtr := add(prevPtr, stride)
                let breakpoint := sub(endPtr, wi)

                for {} lt(prevPtr, breakpoint) 
                { 
                    prevPtr := add(prevPtr, 32) 
                }
                {
                    mstore(prevPtr, vi)
                }
                for {} lt(prevPtr, endPtr) 
                { 
                    prevPtr := add(prevPtr, 32) 
                }
                {
                    mstore(prevPtr, 0)
                }

                prevPtr := add(prev, 32)
                let outPtr := add(out, 32)
                let fwdPtr := add(forward, mul(stride, len))
                let valueWithoutLast := mload(sub(fwdPtr, stride))
                if iszero(eq(mload(fwdPtr), valueWithoutLast))
                {
                    if iszero(lt(bidder, 129))
                    {
                        let payment := sub(valueWithoutLast, sub(optval, vi))
                        mstore(outPtr, or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff)))
                        outPtr := add(outPtr, 32)
                    }
                    fwdPtr := sub(fwdPtr, wi)
                }

                for { let prevRowPtr := add(forward, add(32, mul(stride, sub(len, 3)))) }
                gt(prevRowPtr, forward)
                {
                    prevRowPtr := sub(prevRowPtr, stride)
                }
                {
                    prevPtr := add(prev, 32)
                    fwdPtr := sub(fwdPtr, stride)
                    rbPtr := sub(rbPtr, 32)
                    rbData := mload(rbPtr)
                    wi := shl(5, and(shr(160, rbData), 255))
                    vi := shr(168, rbData)
                    if iszero(eq(mload(fwdPtr), mload(sub(fwdPtr, stride))))
                    {
                        bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                        if iszero(lt(bidder, 129))
                        {
                            let b := 0
                            let localFwdPtr := prevRowPtr
                            let localBwdPtr := prevPtr
                            endPtr := add(localFwdPtr, stride)
                            for {} 
                            lt(localFwdPtr, endPtr)
                            {
                                localFwdPtr := add(localFwdPtr, 32)
                                localBwdPtr := add(localBwdPtr, 32)
                            }
                            {
                                let m := add(mload(localFwdPtr), mload(localBwdPtr))
                                switch gt(b, m)
                                case 0 { b := m }
                            }

                            let payment := sub(b, sub(optval, vi))
                            mstore(outPtr, or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff)))
                            outPtr := add(outPtr, 32)
                        }
                        fwdPtr := sub(fwdPtr, wi)
                    }
                    curPtr := add(curr, 32)
                    endPtr := add(curPtr, stride)
                    breakpoint := sub(endPtr, wi)

                    for {}
                    lt(curPtr, breakpoint)
                    {
                        curPtr := add(curPtr, 32)
                        prevPtr := add(prevPtr, 32)
                    }
                    {
                        let valueWithout := mload(prevPtr)
                        let valueWith := add(vi, mload(add(prevPtr, wi)))
                        switch gt(valueWith, valueWithout)
                        case 0 { mstore(curPtr, valueWithout) }
                        default { mstore(curPtr, valueWith) }
                    }
                    for {}
                    lt(curPtr, endPtr)
                    {
                        curPtr := add(curPtr, 32)
                        prevPtr := add(prevPtr, 32)
                    }
                    {
                        mstore(curPtr, mload(prevPtr))
                    }
                    let tmp := prev
                    prev := curr
                    curr := tmp
                }

                fwdPtr := sub(fwdPtr, stride)
                if gt(mload(fwdPtr), 0)
                {
                    rbPtr := sub(rbPtr, 32)
                    rbData := mload(rbPtr)
                    bidder := and(rbData, 0xffffffffffffffffffffffffffffffffffffffff)
                    wi := shl(5, and(shr(160, rbData), 255))
                    if iszero(lt(bidder, 129))
                    {
                        vi := shr(168, rbData)
                        let payment := sub(mload(add(prev, 32)), sub(optval, vi))
                        rbData := or(shl(168, payment), and(rbData, 0xffffffffffffffffffffffffffffffffffffffffff))
                        mstore(outPtr, rbData)
                        outPtr := add(outPtr, 32)
                    }
                    fwdPtr := sub(fwdPtr, wi)
                }
                mstore(out, shr(5, sub(outPtr, add(out, 32)))) 
            }
            paymentData = storeUintArrayAsBytes(out);
        }
    }

    function mint() external nonReentrant {
        if (auction.status != Status.Finalized) {
            revert AuctionNotFinalizedError();
        }

        Outcome storage outcome = outcomes[msg.sender];
        uint8 current = currentTokenId;
        uint8 end = current + outcome.amount;
        if (current < end){
            outcome.amount = 0;
            for (; current < end; ++current) {
                //if (current > collectionSize) {
                //    revert TotalSupplyExceeded();
                //} // could only happen if there's a bug in vcg
                _safeMint(msg.sender, current);
            }
            currentTokenId = end;
        }
    }

    function withdrawBalance() external onlyOwner {
        uint256 amount = withdrawableBalance;
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
