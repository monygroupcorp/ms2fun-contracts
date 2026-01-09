#!/usr/bin/env bash
set -euo pipefail

# Run from the repo root so `forge` picks up the correct configuration.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/other/repo" >&2
  exit 1
fi

destination="$1"
mkdir -p "$destination"

if ! command -v forge >/dev/null; then
  echo "forge not found in PATH; install Foundry first." >&2
  exit 1
fi

contracts=(
  MasterRegistryV1
  GlobalMessageRegistry
  ERC404BondingInstance
  ERC404Factory
  ERC1155Instance
  ERC1155Factory
  UltraAlignmentVault
  FactoryApprovalGovernance
  VaultApprovalGovernance
)

echo "Building contracts before exporting ABIs..."
forge build

if ! command -v jq >/dev/null; then
  echo "jq not found; install jq to extract ABI JSON from build artifacts." >&2
  exit 1
fi

for contract in "${contracts[@]}"; do
  artifact="out/${contract}.sol/${contract}.json"
  if [ ! -f "$artifact" ]; then
    echo "Artifact not found for $contract at $artifact" >&2
    exit 1
  fi

  target="$destination/${contract}.json"
  printf 'Exporting %s → %s\n' "$contract" "$target"
  jq '.abi' "$artifact" > "$target"
done
