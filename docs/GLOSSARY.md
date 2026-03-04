# Domain Glossary

Terms used throughout the ms2.fun protocol codebase and documentation.

---

## Protocol Concepts

**Alignment Target** — A DAO-approved community profile (e.g., Remilia/CULT, Pudgy Penguins) representing an established crypto community whose token the protocol aligns with. Each target includes a title, description, metadata URI, associated assets, and ambassadors. Managed by `AlignmentRegistryV1`.

**Ambassador** — An address associated with an alignment target, used for curation and governance of that target's community presence. Ambassadors are managed by the DAO through `AlignmentRegistryV1`.

**Benefactor** — A project instance that has contributed fees to a vault. Benefactors earn proportional LP yield from the vault based on the size of their cumulative contributions.

**Conductor** — An external contract granted delegated DAO permissions via a bitmask system. Conductors allow specific operations (e.g., share offerings, stipend distribution, revenue management) without requiring full DAO proposals for each action.

## Revenue & Fees

**Tithe** — The 19% alignment vault contribution taken from each settlement event. Part of the universal fee split: 1% protocol treasury, 19% vault (the tithe), 80% artist.

**Dragnet** — The pool of pending ETH accumulated in a vault before it is converted into alignment token purchases and LP positions. ETH flows in from project tithes and sits in the dragnet until a conversion is triggered.

**Conversion** — The act of swapping a vault's pending ETH (the dragnet) into the alignment token and depositing the result as a full-range Uniswap V4 (or ZAMM/Cypher) LP position. Creates permanent buying pressure and liquidity for the aligned asset.

## ERC404 (Bonding Curve Projects)

**Graduation** — The event triggered when an ERC404 bonding curve reaches full subscription (all tokens sold). Graduation deploys the accumulated reserve as liquidity: 1% to protocol treasury, 19% to the alignment vault, 80% as LP. Post-graduation, the token trades freely with a hook tax flowing to the vault.

**Reroll** — An ERC404 NFT reshuffling mechanism where a holder burns their current NFT and re-mints for a different piece of art from the collection. Costs a fee that flows through the standard revenue split.

## ERC721 (Auction Projects)

**Line** — A parallel auction slot within an ERC721 auction project. Projects can run 1–3 concurrent auction lanes (lines), each operating an independent timed auction.

## Project Lifecycle

**Project Factory** — A code template for a specific project type (ERC404 bonding curve, ERC1155 edition, ERC721 auction). Factories are registered and approved by the DAO via `MasterRegistry`.

**Project Instance** — An artist-created collection deployed from a factory, immutably bound to a vault. Each instance sends fees to its vault according to the universal fee split.

**Vault Instance** — A deployed vault bound to a specific alignment target. Receives tithes from all project instances linked to it, accumulates ETH in the dragnet, and converts to LP positions.
