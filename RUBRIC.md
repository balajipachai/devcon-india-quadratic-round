# Rubric map

Every check the repo is graded on, where it is satisfied, and the test that proves it.
Run `forge test` and every row below must pass. Contract: `src/QuadraticFunding.sol`.

| # | Pts | Check | Where | Test |
|---|----:|-------|-------|------|
| 1 | 15 | Score is the square of the summed square roots, per contributor per project | `contribute` (running total per contributor, root of the total), `quadraticScore` | `test_rubric1_scoreIsSquareOfSummedRoots_handWorked`, `test_rubric1_unequalContributionsHandWorked`, `test_rubric1_splittingOneChequeBuysNothing` |
| 2 | 15 | Matches scaled by the pool over the sum of all weights, so they never exceed it | `finalize`: `mulDiv(pool, matchWeight(i), totalWeight)` | `test_rubric2_matchesScaledToPool_handWorked`, `test_rubric2_matchesNeverExceedPool_andRemainderStaysVisible`, `testFuzz_rubric2_matchesNeverExceedPool` |
| 3 | 10 | `contribute` reverts for an ineligible address, checked in the contract | `contribute`: `MerkleProof.verifyCalldata(proof, eligibilityRoot, _leaf(msg.sender))` | `test_rubric3_ineligibleAddressCannotContribute`, `test_rubric3_emptyProofRejected`, `test_rubric3_proofFromAnotherRoundDoesNotReplay`, `AllowlistTest` |
| 4 | 10 | A project withdraws once; flag written before the transfer | `withdraw`: `p.withdrawn = true` before `.call`, plus `nonReentrant` | `test_rubric4_projectWithdrawsOnce`, `test_rubric4_reentrancyCannotWithdrawTwice` |
| 5 | 6 | Contribution event carries the contributor | `event Contributed(uint256 indexed projectId, address indexed contributor, uint256 amount)` | `test_rubric5_contributionEventCarriesContributor` |
| 6 | 6 | `finalize` reverts before the round ends | `finalize`: `block.timestamp <= roundEnd` reverts | `test_rubric6_finalizeRevertsBeforeRoundEnds`, `test_rubric6_finalizeWorksOnceAfterEnd` |
| 7 | 5 | `contribute` reverts after the round closes | `contribute`: `block.timestamp > roundEnd` reverts | `test_rubric7_contributeRevertsAfterRoundEnds`, `test_rubric7_contributeRevertsBeforeRoundStarts` |
| 8 | 5 | Only the operator registers projects | `registerProject`: `msg.sender != operator` reverts | `test_rubric8_onlyOperatorRegistersProjects` |
| 9 | 3 | Sepolia address recorded in the repo | README "Deployed address", `frontend/deployment.json` | see README |
| 10 | 5 | No credentials in tracked files | keystore signing only; `.env` is git-ignored; `.env.example` has no values | `git grep -nE '0x[0-9a-fA-F]{64}'` finds only Merkle proofs and tx hashes |

## Brief-level traps

| Trap | Defence | Test |
|------|---------|------|
| A square root per transaction | Root of each contributor's running total for the project | `test_rubric1_splittingOneChequeBuysNothing` |
| A committee in disguise | No setter for matches, eligibility or times (all `immutable`); registration closes at round start; no function takes the pool out | `test_trap_operatorCannotAddProjectOnceRoundStarts`, `test_trap_matchingPoolOnlyLeavesViaWithdrawToRecipients`, `test_trap_cannotFundPoolAfterRoundEnds` |
| A results page showing only final numbers | Per-project contributor list, each root, the sum, the score, the breadth bonus and pool share, recomputed in the browser from on-chain events and compared with the contract | exercised in a browser; see README |
| Edge cases | Lone whale, zero-contribution project, rounding remainder, no pool | `test_loneWhaleGetsNoMatchButKeepsOwnMoney`, `test_zeroContributionProjectWithdrawsNothingSafely`, `test_noEligibleBreadthLeavesPoolUnallocated`, `test_contractBalanceEqualsUnallocatedAfterAllWithdrawals` |
