# Sepolia Deployment

**Date:** 2026-03-25
**Deployer:** `0x1821bd18cbdd267ce4e389f893ddfe7beb333ab6`
**Chain ID:** 11155111
**Script:** `script/DeploySepolia.s.sol`

---

## Proxies (vanity `0x00001152` prefix, CREATE3 via CreateX)

| Contract | Address |
|---|---|
| MasterRegistry | `0x000011526343950CfC6D74140F48F8fFdD013d61` |
| ProtocolTreasury | `0x000011525D097FB6f344660c999F88bCD0dff0d7` |
| FeaturedQueueManager | `0x0000115285007e94F9E959bC6a2DaFdf97423A32` |
| GlobalMessageRegistry | `0x00001152a764cb67F7E8971d222a54b01B84F578` |
| AlignmentRegistry | `0x000011521939eCfe7F5A05162734CC8Bd9a20B8A` |
| ComponentRegistry | `0x00001152EC8497A7D8343C38364B9677588e120D` |
| UniAlignmentVault | `0x0000115279605DF875Dc71b1D4e940B3b898E6Cb` |

## Implementations

| Contract | Address |
|---|---|
| MasterRegistryV1 impl | `0x889178D094b24365B292Bd84E9f305022D966d39` |
| ProtocolTreasuryV1 impl | `0xEEAC469e0A73BC9a2c40cFeAf51054A0e10cC06F` |
| FeaturedQueueManager impl | `0xcB1744E527dFD391E032707DB7131991E83AD9e9` |
| GlobalMessageRegistry impl | `0x40A63A9E722E0B46B4548E880e3179Db56bBaa6a` |
| AlignmentRegistry impl | `0xfd5c593e6fB51C48fAdbe9b915C028F7F7A9f282` |

## Peripherals & Factories

| Contract | Address |
|---|---|
| zRouter | `0x0e05f4f236B4955233A018dcC9aFf1173090024b` |
| ERC404Factory | `0x9c7a5892A4B69eEdbE8332f394a0D5ecA1d32617` |
| ERC1155Factory | `0x3055d15aAc79802c65A6d8f1a13751cd2652b9d4` |
| ERC721AuctionFactory | `0x1237fbf33c0401084b5f8f7666C9AC50008131A1` |
| PromotionBadges | `0xe7dA0815EF405F3895D7516b3b528d0449101045` |
| MockSafe | `0x75de49C1aF6bF037E366d2E2D6D7ae9a2573bC6C` |

## Configuration

| Key | Value |
|---|---|
| Alignment token | Chainlink LINK `0x779877A7B0D9E8603169DdbD7836e478b4624789` |
| Alignment target ID | 1 |
| V4 pool key | ETH/LINK, fee=3000, tickSpacing=60, hooks=address(0) |
| V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
