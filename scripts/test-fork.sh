#!/bin/bash
# Run fork tests against running anvil instance
# Usage: ./scripts/test-fork.sh [test-path]
# Example: ./scripts/test-fork.sh test/fork/v2/V2PairQuery.t.sol

set -e

# Check if anvil is running
if ! nc -z 127.0.0.1 8545 2>/dev/null; then
    echo "Error: Anvil is not running on port 8545"
    echo "Start it first with: ./scripts/start-fork.sh"
    exit 1
fi

# Default to all fork tests if no argument provided
TEST_PATH="${1:-test/fork/**/*.sol}"

echo "Running fork tests: $TEST_PATH"
echo "Against: http://127.0.0.1:8545"
echo ""

forge test \
    --match-path "$TEST_PATH" \
    --fork-url "http://127.0.0.1:8545" \
    -vv
