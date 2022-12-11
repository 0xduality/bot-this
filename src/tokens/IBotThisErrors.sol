// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

/// @title Custom 
interface IBotThisErrors {
    error AlreadyStartedError();
    error TopBiddersOddError();
    error AuctionNotFinalizedError();
    error RevealPeriodOngoingError();
    error BidPeriodOngoingError();
    error BidPeriodTooShortError(uint32 bidPeriod);
    error RevealPeriodTooShortError(uint32 revealPeriod);
    error NotInRevealPeriodError();
    error NotInBidPeriodError();
    error UnrevealedBidError();
    error ZeroCommitmentError();
    error TotalSupplyExceeded();
    error InvalidStartTimeError(uint32 startTime);
    error InvalidOpeningError(bytes21 bidHash, bytes21 commitment);
}
