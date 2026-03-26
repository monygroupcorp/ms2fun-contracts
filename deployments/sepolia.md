# Sepolia Deployment

**Date:** 2026-03-26
**Deployer:** `0x1821BD18CBdD267CE4e389f893dDFe7BEB333aB6`
**Chain ID:** 11155111
**Script:** `script/DeploySepolia.s.sol`
**Transactions:** 46
**All 26 contracts verified on Etherscan**

---

## Proxies (vanity `0x00001152` prefix, CREATE3 via CreateX)

| Contract | Address |
|---|---|
| MasterRegistry | `0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF` |
| ProtocolTreasury | `0x00001152e56eb45082De505e9E9be5DC158E4cfC` |
| FeaturedQueueManager | `0x00001152c0715721Ae4D2b0B693862953DCFB99C` |
| GlobalMessageRegistry | `0x0000115268C7cB1a508ec18DA1cB2D71c0B2C637` |
| AlignmentRegistry | `0x00001152db13C4AFb4d9F4bbA93F364692F372eB` |
| ComponentRegistry | `0x00001152Ed1bD8e76693cB775c79708275bBb2F3` |

## Factories

| Contract | Address |
|---|---|
| ERC404Factory | `0xd84f755AdFac9408ADbde65832F8A1BFf5179bF8` |
| ERC1155Factory | `0x8b4282aBCE5DeF5ab9f5D4501182503492CD1C4B` |
| ERC721AuctionFactory | `0x073BBb8DF32b2228B6f08fAFc7d144ef911e2082` |

## Peripherals

| Contract | Address |
|---|---|
| QueryAggregator | `0x087179Ff25bD47E72fd45d21a92Efad2B0B103e6` |
| LaunchManager | `0x354768153a0d3edC314D9f6baa2fd56a6961B449` |
| CurveParamsComputer | `0xfc0189E52Df95E1078f7DeC74d8e6849AFf84eaa` |
| DynamicPricingModule | `0x88B71cbCC6A62d5b76cc16Df35A0c063B6a84EB2` |
| UniswapVaultPriceValidator | `0x2d3C9f10671314639FCBD4d85F3DcfbFF2D5610E` |
| zRouter | `0x4ABdEaB1A6Dca8CEFB3280cb2843DDbEf0FA1CFB` |

## Alignment Vaults

| Target | Type | Token | Target ID | Address |
|---|---|---|---|---|
| Chainlink (LINK) | UNIv4 | `0x779877A7B0D9E8603169DdbD7836e478b4624789` | 1 | `0xf456B56E210924c249db834504a97c4A15D57cd8` |

## Configuration

| Key | Value |
|---|---|
| V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| V3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| V2 Factory | `0xF62c03E08ada871A0bEb309762E260a7a6a880E6` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| Alignment token | Chainlink LINK `0x779877A7B0D9E8603169DdbD7836e478b4624789` |

## CREATE3 Salts

| Contract | Salt |
|---|---|
| MasterRegistry | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6006fc783a2ee2a5801bcc77a` |
| ProtocolTreasury | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60082245dad1d7c3e0071f20f` |
| FeaturedQueueManager | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600cf49066351827200ad2a5e` |
| GlobalMessageRegistry | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6006b9e54d6a39a0801f14fa8` |
| AlignmentRegistry | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab60057d45cf31029d003f61c1d` |
| ComponentRegistry | `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab600586503138e974c00a226d9` |
