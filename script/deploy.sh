#!/usr/bin/env bash
# Builds the eligibility list for the address the contract is about to get, deploys the round,
# registers its projects, funds the pool, verifies the source, and confirms the deployment landed.
#
# Reads from .env: SEPOLIA_RPC_URL, DEPLOYER (keystore account address), MEMBERS_FILE,
#   PROJECT_RECIPIENTS, PROJECT_NAMES (comma-separated, same length), REGISTRATION_SECONDS,
#   ROUND_SECONDS, optional POOL_WEI and ETHERSCAN_API_KEY. The signer is the Foundry keystore
#   KEYSTORE_ACCOUNT (default: deployer). No private key is read from any file.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a

for v in SEPOLIA_RPC_URL DEPLOYER MEMBERS_FILE PROJECT_RECIPIENTS PROJECT_NAMES REGISTRATION_SECONDS ROUND_SECONDS; do
  [ -n "${!v:-}" ] || { echo "error: $v is not set (add it to .env)" >&2; exit 1; }
done
ACCOUNT="${KEYSTORE_ACCOUNT:-deployer}"
CHAIN_ID=11155111
[ "$(cast chain-id --rpc-url "$SEPOLIA_RPC_URL")" = "$CHAIN_ID" ] || { echo "error: RPC is not Sepolia" >&2; exit 1; }

# The leaf includes the contract address, so build the list for the address the deploy will create:
# it is the first transaction the broadcast sends from DEPLOYER.
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$SEPOLIA_RPC_URL")
PREDICTED=$(cast compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
[ -d tools/node_modules ] || (cd tools && npm install --silent)
node tools/merkle.mjs "$MEMBERS_FILE" "$PREDICTED" frontend/allowlist.json
export ELIGIBILITY_ROOT=$(python3 -c "import json;print(json.load(open('frontend/allowlist.json'))['root'])")

# --skip-simulation takes gas estimates from the node: forge's local estimate is far below what Sepolia
# charges for contract creation, which made an earlier deployment run out of gas and deploy nothing.
verify_args=(--verify --verifier sourcify)
[ -n "${ETHERSCAN_API_KEY:-}" ] && verify_args=(--verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY")

forge script script/Deploy.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" --account "$ACCOUNT" --sender "$DEPLOYER" \
  --broadcast --skip-simulation --slow "${verify_args[@]}"

RECORD="broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
read -r ADDRESS TX < <(python3 -c "
import json
t=json.load(open('$RECORD'))['transactions'][0]
print(t['contractAddress'], t['hash'])")

STATUS=$(cast receipt "$TX" status --rpc-url "$SEPOLIA_RPC_URL" || true)
CODE=$(cast code "$ADDRESS" --rpc-url "$SEPOLIA_RPC_URL")
if [[ "$STATUS" != "true" && "$STATUS" != 1* && "$STATUS" != *success* ]] || [ "$CODE" = "0x" ]; then
  echo "DEPLOY FAILED: tx $TX status='$STATUS', no code at $ADDRESS. Do not record this address." >&2; exit 1
fi
if [ "$(echo "$ADDRESS" | tr A-F a-f)" != "$(echo "$PREDICTED" | tr A-F a-f)" ]; then
  echo "ADDRESS MISMATCH: deployed $ADDRESS but the allowlist was built for $PREDICTED." >&2
  echo "Nobody could contribute. Re-run with a fresh nonce; do not use this deployment." >&2; exit 1
fi

# every registered project and the funded pool must be on-chain too
EXPECTED=$(echo "$PROJECT_RECIPIENTS" | tr ',' '\n' | wc -l | tr -d ' ')
COUNT=$(cast call "$ADDRESS" 'projectCount()(uint256)' --rpc-url "$SEPOLIA_RPC_URL")
[ "$COUNT" = "$EXPECTED" ] || { echo "PARTIAL DEPLOY: $COUNT of $EXPECTED projects registered at $ADDRESS" >&2; exit 1; }

BLOCK=$(cast receipt "$TX" blockNumber --rpc-url "$SEPOLIA_RPC_URL")
printf '{\n  "address": "%s",\n  "chainId": %s,\n  "deployBlock": %s\n}\n' "$ADDRESS" "$CHAIN_ID" "$BLOCK" > frontend/deployment.json

echo
echo "Deployed QuadraticFunding at $ADDRESS (block $BLOCK)"
echo "  projects:   $COUNT"
echo "  pool:       $(cast call "$ADDRESS" 'matchingPool()(uint256)' --rpc-url "$SEPOLIA_RPC_URL") wei"
echo "  roundStart: $(cast call "$ADDRESS" 'roundStart()(uint256)' --rpc-url "$SEPOLIA_RPC_URL")"
echo "  roundEnd:   $(cast call "$ADDRESS" 'roundEnd()(uint256)' --rpc-url "$SEPOLIA_RPC_URL")"
echo "  https://sepolia.etherscan.io/address/$ADDRESS"
echo "Wrote frontend/deployment.json and frontend/allowlist.json. Next: record the address in README.md."
