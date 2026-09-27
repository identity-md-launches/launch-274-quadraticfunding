# Local validation and review handoff

This is a source-producer test record, **not an independent security review**. The separate
reviewer must examine the accepted contracts and launch manifest before deployment. No review
of signed artifacts, policy admission, deployed addresses, or a frontend is claimed.

## Recorded results

Using Foundry 1.8.3 and the pinned Solidity 0.8.26 compiler:

| Check | Result |
| --- | --- |
| `forge build` / `forge build --sizes` | Passed |
| `forge test` | 44 passed, 0 failed, 0 skipped |
| `env -i /root/.foundry/bin/forge test --threads 4` | 44 passed with an empty environment and four threads |
| Stateful invariant in each full run | 128 runs, 8,192 calls, 0 reverts; final collection succeeded |
| `forge fmt --check` | Passed |
| Exported JSON ABI versus compiled artifact ABI | Exact equality for both contracts |
| Production runtime sizes | LaunchToken: 1,709 bytes; QuadraticFunding: 6,298 bytes |

The `/root/.foundry/bin/forge` path above is this worker's executable location, not a repository
dependency. Build output contains nonfatal static lint warnings; the compiler reports success.
The service-driven protected harness requires launch artifact/environment inputs; this contribution
does not claim to have run that harness. Local tests independently exercise its supply,
factory-construction, size, and forbidden-opcode baseline on the compiled contracts.

## Automated coverage

- `test/LaunchToken.t.sol`: token metadata, exact fixed supply and transfers, ERC-20 approvals,
  insufficient balance/allowance, zero recipient, unavailable admin/mint selectors, CREATE2
  factory construction without initialization or application funding, invalid token arguments,
  EIP-170 size, and executable opcode scanning for DELEGATECALL/CALLCODE/SELFDESTRUCT.
- `test/QuadraticFunding.t.sol`: sqrt edge cases including `uint256.max` and square neighbors,
  fuzzed floor-sqrt properties, repeated-payment roots compared with fresh per-address sums,
  exact known allocations, tiny-pool dust and nonzero-ID tie winners, fuzzed whole-pool allocation
  and payouts, full-supply deposits across all 50 projects, creator authorization, cap, invalid
  identifiers/schedules/amounts, start/end boundaries, approval failure rollback, event fields,
  no-project and zero-contribution refunds, multiple/repeated funders, zero-pool/empty-project
  claims, early/unauthorized/double claims, double finalization, round isolation, donation handling,
  ETH rejection, and the effect of Sybil splitting.
- `test/TokenSafety.t.sol`: false-return, reverting, no-return and fee-on-transfer mock tokens;
  failed claims/refunds preserve retry rights and do not block others; finalization makes no
  token transfers; callback reentrancy into paying, registration, creation and collection paths
  is rejected; a mock with `uint256.max` supply cannot exceed the explicit round deposit bound.
- `test/Conservation.invariant.t.sol`: randomized funding, repeated contributions, clock advances,
  finalizations, claims, and reclaims across three rounds and four actors. At every step,
  deposited minus paid tokens equal application custody and unpaid liabilities; per-account
  contribution totals and roots agree with independent handler records; all nonrefundable
  finalized pools are allocated exactly. Every run then finalizes and collects every entitlement,
  requiring zero remaining application balance. Token supply and tracked balances are conserved.

The default profile runs each fuzz test **512 times** and the stateful invariant **128 runs ×
64 calls** with `fail_on_revert = true`. Handlers intentionally skip actions that are not yet
eligible; explicit unit tests exercise those revert paths. All tests use isolated local state,
explicit timestamps/configuration, and no environment reads/writes or network forks.

## Review focus and limits

The arithmetic proof is in README.md and the implementation beside `_matchingAmounts`.
The explicit supply bound applies to pool plus contributions, independently in each round.
The tests cannot enumerate a billion distinct minimum-size contributors; safety at that bound
rests on the documented inequality, checked arithmetic, and minimum contribution rule.

The chosen immutable production token is essential. Generic token mocks test failure isolation
and reentrancy defense, but they cannot establish safety for every malicious token. Direct token
donations and forced ETH are irrecoverable. Payout contracts must support initiating `claim`.
Creator-controlled curation, late registration, duplicate beneficiaries, absence of identity
checks, Sybil incentives, and the absence of an emergency administrator are intentional and
must remain visible to participants.

Before release the independent reviewer should specifically challenge: constructor-to-token
linkage in the manifest, overflow and rounding bounds, funder versus recipient entitlements,
arbitrary registration attempts, early/duplicate collection, end-time inclusivity, and the
operational disclosures. Tests establish local behavior, not service execution or launch approval.
