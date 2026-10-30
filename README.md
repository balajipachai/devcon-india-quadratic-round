# Two Hundred Small Backers Should Beat One Whale

A quadratic-funding round for grassroots projects, paid in ETH. Eligible community members contribute during a fixed
window, and when it closes each project's match comes from a fixed pool in proportion to how *broad* its support was,
not how big any one cheque was. Every number can be checked from the blockchain.

See [`RUBRIC.md`](RUBRIC.md) for a check-by-check map from the grading rubric to code and tests.

## How the match is worked out

For each project:

1. **Aggregate per person.** Each eligible address's gifts to the project are added into one running total.
2. **Score** = (Σ √total_i)². One person splitting a cheque across a hundred transactions still has one total and one
   root, so splitting buys nothing.
3. **Breadth bonus** = score − what people actually gave. One backer alone gives a bonus of exactly zero; many backers
   give a large one. Only the bonus is matched.
4. **Match** = pool × (project's bonus ÷ every project's bonus), rounded down. Matches add up to at most the pool, and
   any rounding dust stays visible as `unallocated()`.

Hand-worked (also a unit test): pool 84 ETH. Project A has 4 backers giving 1 ETH each: score (4×1)² = 16, bonus 16 − 4 =
**12**. Project B has 9 backers giving 1 ETH each: score 81, bonus 81 − 9 = **72**. Bonuses total 84, so A gets
**12 ETH** and B gets **72 ETH**. A lone 100 ETH backer on a third project would get a bonus of 0.

Square roots are integer math: `Math.sqrt(total × 1e18)` (OpenZeppelin, rounded down), so a few wei of precision is not
lost to a root of a small number. Scores are divided back by 1e18.

## Round lifecycle

| Phase | When | What happens |
|-------|------|--------------|
| Registration | before `roundStart` | The operator registers projects (up to 50). Anyone may fund the matching pool. |
| Contribution | `roundStart` to `roundEnd` | Eligible members contribute to any project. Pool funding stays open. |
| Closed | after `roundEnd` | Anyone calls `finalize()` once, fixing every match. |
| Payout | after `finalize()` | Anyone can trigger each project's `withdraw()`, once. It pays contributions plus match to that project's recipient. |

## What nobody can do (no committee)

- **Operator** can register projects, and only before the round starts. There is no function to change a match,
  edit the eligibility list, add a project mid-round, shorten the round, or take the pool out.
- **Eligibility** is a Merkle root fixed in the constructor. `contribute()` verifies a proof against `msg.sender` in the
  contract. The leaf includes the contract's address, so a list built for another deployment can't be replayed.
- **Payouts** can only go to the recipient registered before the round, no matter who presses the button.

## Layout

- `src/QuadraticFunding.sol`: the contract (OpenZeppelin `ReentrancyGuard`, `MerkleProof`, `Math`).
- `test/`: 33 tests. A hand-worked example, the split-cheque attack, a fuzz test that matches never exceed the pool,
  both-direction reentrancy, boundary timing, and a cross-check that the JS Merkle tool and the contract agree.
- `tools/merkle.mjs`: builds the eligibility tree and each member's proof.
- `script/Deploy.s.sol`, `script/deploy.sh`: deploy, register projects, fund the pool, verify, confirm.
- `frontend/`: the results page. For each project it shows who gave what, each square root, the sum, the score, the
  breadth bonus and the pool share, and recomputes all of it in the browser from the contract's `Contributed` events,
  comparing the result with the contract's own number. Amounts are in ETH.

## Deploy (Sepolia)

The signer is a Foundry keystore (`cast wallet import deployer --interactive`), never a file in this repo. Copy
`.env.example` to `.env` and fill it in (it is git-ignored), put the eligible addresses in `MEMBERS_FILE`, then:

```sh
script/deploy.sh
```

The script builds the allowlist for the address the contract is about to get (the leaf includes it), deploys,
registers the projects, funds the pool, verifies the source, then checks the receipt, the on-chain code, that the
address matches the one the allowlist was built for, and that every project registered. It writes
`frontend/deployment.json` and `frontend/allowlist.json`.

It uses `--skip-simulation` because forge's local gas estimate is far below what Sepolia charges for contract
creation; a transaction sized by the local estimate ran out of gas on-chain and deployed nothing.

Serve the page with any static host, e.g. `cd frontend && python3 -m http.server 8000`.

### Deployed address

| Network | Address |
|---------|---------|
| Sepolia | _pending deployment_ |

## Verification performed

| Layer | Result |
|-------|--------|
| `forge test` | 33 tests pass |
| Slither | 0 findings; accepted `timestamp` and `low-level-calls` notes are suppressed inline with a reason |
| Anvil end to end | Deploy script (predicted address matched, 3 projects, pool funded), contributions through the page, an outsider refused, finalize and every payout through the page; recipients received exactly what the page showed and the contract kept only the 1 wei rounding dust |
