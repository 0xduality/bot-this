// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

/// @title Custom
interface IBotThisErrors {
    error StepASkippedError();
    error StepBSkippedError();
    error StepAlreadyExecutedError();
    error WaitUntilAfterRevealError();
    error AlreadyStartedError();
    error TopBiddersOddError();
    error AuctionNotFinalizedError();
    error RevealPeriodOngoingError();
    error BidPeriodOngoingError();
    error BidPeriodTooShortError();
    error RevealPeriodTooShortError();
    error NotInRevealPeriodError();
    error NotInBidPeriodError();
    error UnrevealedBidError();
    error ZeroCommitmentError();
    error TotalSupplyExceeded();
    error InvalidStartTimeError();
    error CollateralLessThanReservePriceError();
    error InvalidOpeningError(bytes21 bidHash, bytes21 commitment);
}
