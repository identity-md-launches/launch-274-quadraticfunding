# Match quadratic funding

Foundry contracts for the Sepolia project **lab-quadratic-funding**: the fixed-supply
Match token (**MTCH**) and permissionless, creator-curated funding rounds paid entirely in MTCH.

This contribution delivers contracts, local tests, and ABI exports. The generated `launch.json`,
independent adversarial review, service publication/attestation/admission/deployment, and website
are separate stage responsibilities. No deployment, signed attestation, or independent audit is
claimed here.

## Build and check

With Foundry and Solidity **0.8.26** available:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins the compiler, Cancun EVM, optimizer (200 runs), and
`bytecode_hash = "none"`; CBOR metadata is disabled. Dependencies are ordinary vendored files
under `lib/`, with versions and licenses described in [lib/README.md](lib/README.md).
There is no dependency installation step, submodule, FFI, filesystem permission, or environment
configuration required by the tests. Tests use fresh deployments and explicit parameters.

Regenerate the deliverable ABIs after changing source:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/QuadraticFunding.sol:QuadraticFunding abi --json > docs/abi/QuadraticFunding.json
```

See [the ABI integration guide](docs/ABI.md) for calls, tuple fields, and event discovery.

## Deployment parameters

| Item | Required value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Project kind | `evm_project` |
| Launch token source | `src/LaunchToken.sol:LaunchToken` |
| Launch token arguments | `[]` (nonpayable constructor) |
| Metadata | `Match`, `MTCH`, 18 decimals |
| Supply | `1000000000000000000000000000` base units (`1,000,000,000 MTCH`) |
| Application identifier | `QuadraticFunding` |
| Application source | `src/QuadraticFunding.sol:QuadraticFunding` |
| Application arguments | `["$token"]` (one `address`, nonpayable constructor) |
| Owner/roles/init calls | None |

The project factory deploys the token first and receives its entire supply, then deploys
QuadraticFunding with the token address. Construction only stores that immutable address;
it does not move any tokens, require an application balance, call back into the factory,
or require subsequent initialization. The constructor rejects zero and addresses without code;
the deployment service and independent reviewer must ensure the argument is the accepted
LaunchToken, since an arbitrary contract with code can pass that check.

The factory distributes supply to liquidity and protocol rewards under its pinned policy.
Contributors obtain MTCH by **swapping Sepolia ETH in the launch pool**. The application does
not sell, mint, or swap MTCH. No privileged wallet is hard-coded. There is no mint-after-deploy,
owner, admin, pause, fee, blocklist, upgrade, or withdrawal backdoor in either contract.

The manifest contributor describes these artifacts and their dependency order. Services own
policy validation, signed artifact linkage, source publication, attestation, admission, factory
transactions, and the deployed addresses/block numbers used by the frontend. Pool/reward policy
parameters are service responsibilities, not constructor inputs. This repository includes no
wallet key access or broadcast script. Network selection is operational; the contracts do not
hard-code a chain restriction.

## Round lifecycle and accounting

All amounts below are **MTCH base units**. One MTCH is `10^18` units. IDs are zero-based.

1. Anyone calls `createRound(start, end)`. `start >= block.timestamp`, and duration must be
   between **1 and 30 days inclusive**. Timestamps are Unix seconds.
2. Only that round's creator can `register(roundId, payout)`, before `end`. Each round has at
   most **50 projects** and every payout must be nonzero. Registration is allowed both before
   and during contributions. Entries and payouts cannot be changed or removed. Duplicate
   payout addresses are permitted; distinct project IDs maintain separate accounting.
3. Anyone can `fund(roundId, amount)` before `end`, including before `start`. Every positive
   amount is accepted, including less than one MTCH. Each funder's deposits accumulate.
4. Anyone can `contribute(roundId, projectId, amount)` during **`[start, end)`**. Every call must
   pay at least **one MTCH**. First call `MTCH.approve(QuadraticFunding, amount)` and confirm
   sufficient allowance/balance. Both paying methods use `SafeERC20.safeTransferFrom` and
   require receipt of exactly the requested amount.
5. Anyone calls `finalize(roundId)` **at or after `end`**, once. It makes no external token
   calls. Up to 50 projects are evaluated; it never loops over contributors or funders.
6. If any contribution exists, each configured payout address calls `claim(roundId, projectId)`
   once to receive that project's contributions plus match. Claims are pull-based, nonReentrant,
   and follow checks-effects-interactions. Only the payout can claim; callers cannot redirect it.
7. If no contribution exists (`Q == 0`), each funder instead calls `reclaim(roundId)` to recover
   its own accumulated funding. Each successful reclaim consumes that balance. Empty-project
   zero claims are harmless and do not consume the refundable pool.

There is no automatic settlement, cancellation, early withdrawal, or claim/refund deadline.
Funders cannot withdraw from a round that received contributions. Contributors cannot reverse
their payments. Any participant may finalize; recipients and funders must submit their own
collection transactions. A failed transfer reverts its accounting and may be retried; it does
not block unrelated claims/refunds. Payout addresses must be able to originate a call to the
contract (EOA or suitably programmed contract). A lost key or unusable payout permanently locks
that project's entitlement; the curator cannot repair it later.

The contracts have no payable function and no receive/fallback; normal ETH payments revert.
The EVM can still force ETH to an address, which cannot be prevented or recovered here.
Unsolicited direct MTCH transfers are not credited to rounds and have no recovery path. Use
`fund`/`contribute` after approving instead of sending tokens directly. MTCH is the only supported
production currency; inbound transfer checks are defensive, not general support for rebasing,
fee-charging, malicious, or upgradeable tokens.

## Exact matching rule

For each contributor's accumulated project total `t`, use OpenZeppelin's integer
`Math.sqrt(t)` on **base units**, rounded down. Repeated contributions replace that contributor's
old root with the new root:

```text
sumSqrt[p] += floor(sqrt(oldTotal + amount)) - floor(sqrt(oldTotal))
q[p]        = sumSqrt[p] * sumSqrt[p]
Q           = sum(q[p])
match[p]    = floor(pool * q[p] / Q)  // OpenZeppelin Math.mulDiv
```

When `Q > 0`, the entire leftover `pool - sum(match[p])` goes to the project with the **largest
q**, selecting the **lowest project ID on ties**. This includes all rounding dust, even for a
tiny pool. Thus `sum(match[p]) == pool` exactly. When `Q == 0`, all matches are zero and the pool
is refundable. `estimateMatch` uses exactly the same allocation, including the remainder; it
is a changing estimate before finalization and the stored allocation afterwards.

Per-round funding plus contributions is explicitly limited to the token's fixed supply,
`10^27`. This is already the maximum possible for MTCH, since no round pays out while accepting
deposits. It also bounds arithmetic if the wrong token is supplied: every positive contributor
total `t >= 10^18`, so `floor(sqrt(t)) <= t / 10^9`. Across a round, the sum of all roots is at
most `10^18`, each weight and `Q` are at most `10^36`, and even `pool * q <= 10^63 < 2^256`.
`Math.mulDiv` additionally performs multiplication with full precision. Checked arithmetic is
retained throughout. Fund accounting is separate per round even though token custody is shared.

## Trust and operation

**The round creator curates the project list.** The creator can choose beneficiaries, register
multiple IDs for a beneficiary, fill the cap, or add projects until the round ends. Funding a
round expresses trust in its creator's curation. The creator cannot seize funds, change existing
payouts, cancel a round, or bypass contribution/settlement rules. There is no global administrator.

**Quadratic funding is Sybil-able: splitting contributions across addresses raises the match.**
Repeated payments from one address are aggregated, but wallets are not people. There is **no
identity check on Sepolia**. This implementation intentionally applies the approved formula,
not a claim of fair identity-based allocation. Floor rounding and dust favor the specified largest
weight/lowest-ID winner. Operators must communicate these trade-offs before soliciting funds.

The source producer's tests are not a security audit. Before release, an **independent contributor**
must review accepted source and the generated manifest together, including constructor linkage,
overflow bounds, dust conservation, payout/refund authorization, time boundaries, and the curation
and Sybil assumptions. Review findings remain findings; passing tests do not replace that stage.
See [validation notes](docs/VALIDATION.md) for the implemented adversarial cases and test limits.

After service deployment, the frontend contributor builds the approved small static page with
`dist/index.html`. It must read the token address via `token()`, show wallet balance/allowance,
provide an Approve step before funding/contributing, and explain the external Sepolia ETH-to-MTCH
pool swap. It should show rounds, projects, contributions, and live match estimates using views
and events only (no backend/indexer), and expose create, creator-only register, fund, contribute,
finalize, payout-only claim, and funder reclaim actions. Deployment addresses, deployment block,
RPC/log pagination, transaction confirmation, chain checking, and hosting are subsequent
operational inputs. This source assignment does not depend on those later outcomes.
