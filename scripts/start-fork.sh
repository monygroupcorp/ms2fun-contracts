#!/bin/bash
# Start anvil fork of Ethereum mainnet
# Run this in a separate terminal and keep it running

set -e

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found"
    exit 1
fi

if [ -z "$ETH_RPC_URL" ]; then
    echo "Error: ETH_RPC_URL not set in .env"
    exit 1
fi

echo "Starting Anvil fork..."
echo "RPC: $ETH_RPC_URL"
echo "Block: 23724000"
echo ""
echo "Once anvil is running, use scripts/test-fork.sh to run tests"
echo ""

anvil --fork-url "$ETH_RPC_URL" --fork-block-number 23724000 --hardfork cancun
