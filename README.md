# bot-this • ![license](https://img.shields.io/github/license/0xduality/bot-this?label=license) ![solidity](https://img.shields.io/badge/solidity-^0.8.16-lightgrey)

An ERC721 compatible contract that awards NFTs based on a [VCG auction](https://en.wikipedia.org/wiki/Vickrey%E2%80%93Clarke%E2%80%93Groves_auction).

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
├─ BotThis — The NFT contract implementing the auction
├─ ERC721 — Minimally modified ERC721 base from solbase
├─ IBotThisErrors — Custom errors
test
└─ BotThis.t — Tests
```

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
