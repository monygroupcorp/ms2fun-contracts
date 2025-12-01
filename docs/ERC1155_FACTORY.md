# ERC1155 Factory

## Overview

The ERC1155 Factory deploys ERC1155 multi-edition token instances.

## Features

- Multiple editions per instance
- Per-edition pricing
- Supply management
- Metadata per edition
- Royalty support

## Usage

```solidity
// Create an instance
factory.createInstance(
    name,
    metadataURI,
    creator
);

// Add an edition
factory.addEdition(
    instance,
    pieceTitle,
    price,
    supply,
    metadataURI
);
```

