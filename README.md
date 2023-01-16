# bot-this • ![license](https://img.shields.io/github/license/0xduality/bot-this?label=license) ![solidity](https://img.shields.io/badge/solidity-^0.8.16-lightgrey)

ERC721 compatible contracts that award NFTs based on a [VCG auction](https://en.wikipedia.org/wiki/Vickrey%E2%80%93Clarke%E2%80%93Groves_auction). 
VCG auctions ensure that auctioned goods are given to those that value them the most.
In a VCG auction a bidder cannot profit by bidding something other than their true value.

This repository contains two contracts: `BotThis` and `BotThisSimple`. The difference between the two is that  
`BotThis` allows specifying the amount of NFTs each bidder wants while `BotThisSimple` assumes one NFT per bidder (wallet).
`BotThis` runs a true VCG auction, while in `BotThisSimple` the VCG auction reduces to a simple auction where
in a collection with `N` items all winners winners pay the price of the `N+1`-st bid.

However, the additional flexibility of `BotThis` comes with substantial complexity of implementation. 
Determining the winners of the auction and their payments in `BotThis` requires substantially more gas
than `BotThisSimple`. The gas requirements are so large that only collections with small number of NFTs 
can be auctioned before exhausting all gas in a block (even though all code for the core of the auction is 
written in Yul). For this reason, in `BotThis` we introduce an additional short list of top bidders: 
bidders whose value per item is large. We run the auction only among the top bidders rather than all bidders.
In `BotThisSimple` the gas requirements are very modest and we do not use a short list of top bidders.

## Getting Started

Assuming you have [foundry](https://getfoundry.sh/) installed
```sh
git clone --recursive https://github.com/0xduality/bot-this
cd bot-this
forge test
```

## Blueprint

```ml
lib
├─ forge-std — https://github.com/foundry-rs/forge-std
├─ solbase — https://github.com/Sol-DAO/solbase
scripts
├─ Deploy.s.sol — Simple deployment script
src
├─ BotThis — The NFT contract implementing the full VCG auction
├─ BotThisSimple — The NFT contract implementing a simplified auction
├─ ERC721 — Minimally modified ERC721 base from solbase
├─ IBotThisErrors — Custom errors
test
└─ BotThis.t — Tests
```

## Overview of Operations

The two contracts are pretty similar. At deployment time we specify the size of the collection (and the amount of top bidders for 
`BotThis`). Then the owner can call `createAuction` to specify a reserve price (below which a bid won't be considered), when the auction 
bidding phase starts, when it ends and the reveal phase starts, and when the reveal phase ends. Before the bidding starts the owner 
can call createAuction again to move the auction further into the future and/or change some parameters.

During the bidding phase, users submit 
commitments to their bid via `commitBid`. The commitment, which is a hash also carries a collateral. The hash is the result of hashing 
the actual bid plus a _salt_ that the user needs to remember until the reveal phase. During the reveal phase the bidder submits the 
actual bid information and the _salt_ via the `revealBid` method. The contract verifies that hashing these produces the same hash as 
the commitment. It also verifies that the collateral posted with `commitBid` exceeds the amount in the bid (if not the user is refunded
and will not participate in the auction). 

Once the reveal period is over the owner can call `finalizeAuction` or `cancelAuction`. `cancelAuction` simply cancels the auction. No NFTs can be minted and all bidders can fully withdraw their collateral. `finalizeAuction` determines the winners and their payments among the revealed bids. 
For `BotThis` the gas required for `finalizeAuction` may not fit in a single block which is why the contract provides an alternative way to finalize the auction by calling `finalizeAuctionStepA`, `finalizeAuctionStepB`, and `finalizeAuctionStepC` as three separate transactions.

After the auction is finalized, winners of the auction can `mint` their NFTs. Everyone with a valid bid can call `withdrawCollateral` to receive their collateral minus any minting costs if they won the auction. 

What about bidders who lost their _salt_ or could not otherwise reveal their bid. These folks can call `emergencyReveal` after the auction has been finalized. This marks the bid as revealed which allows the user to call `withdrawCollateral`. Therefore users who could not reveal their bid on time do not lose their collateral but also do not participate in the finalization of the auction so they cannot win any NFTs.

Currently, if the collection is not sold out via the auction it is impossible to mint the remaining NFTs. It is easy to modify the contract to include a period after which any remaining NFTs can be minted by anyone at the reserve price (or another price).

## License

[AGPL-3.0-only](https://github.com/0xduality/bot-this/blob/main/LICENSE)


## Acknowledgements

The following projects had a substantial influence in the development of this project.

- [auction-zoo](https://github.com/a16z/auction-zoo)
- [femplate](https://github.com/abigger87/femplate)
- [foundry](https://github.com/foundry-rs/foundry)
- [solbase](https://github.com/Sol-DAO/solmate)
- [forge-std](https://github.com/brockelmore/forge-std)


## Disclaimer

_These smart contracts are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of the user interface or the smart contracts. They have not been audited and as such there can be no assurance they will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk._
