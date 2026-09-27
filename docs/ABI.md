# ABI integration

The generated JSON arrays in [LaunchToken.json](abi/LaunchToken.json) and
[QuadraticFunding.json](abi/QuadraticFunding.json) are the full compiler ABIs, including custom
errors and events. Supply `bigint`/arbitrary-precision values; JavaScript `Number` cannot safely
represent MTCH amounts. All application state-changing calls are **nonpayable**.

## Token

`LaunchToken()` has no arguments. ERC-20 methods: `name()`, `symbol()`, `decimals()`,
`totalSupply()`, `balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`,
`transfer(address,uint256)`, `transferFrom(address,address,uint256)`. Supply is always `10^27`.
There is no permit or privileged method. The payer approves the **application address**, not the
round creator or payout. An exact approval of the next payment is sufficient. Standard ERC-20
allowance semantics apply; an existing unbounded approval need not be renewed.

## Application calls

`QuadraticFunding(address token_)` stores its one dependency immutably. Valid IDs start at zero;
`roundCount()` is the number of rounds, and each `round(id).projectCount` is its project count.
Every user action is detailed in [README.md](../README.md).

| Method | Result / caller / boundary |
| --- | --- |
| `createRound(uint256 start,uint256 end)` | Returns round ID; anyone; start is now or later, duration 1–30 days |
| `fund(uint256 roundId,uint256 amount)` | Caller pays positive MTCH amount; before end |
| `register(uint256 roundId,address payout)` | Returns project ID; creator only; before end; cap 50 |
| `contribute(uint256 roundId,uint256 projectId,uint256 amount)` | Caller pays at least `10^18`; start inclusive, end exclusive |
| `finalize(uint256 roundId)` | Anyone; end inclusive; once |
| `claim(uint256 roundId,uint256 projectId)` | Project payout only; finalized; once |
| `reclaim(uint256 roundId)` | Funder recovers its funding; finalized with `Q == 0`; once per funded balance |
| `round(uint256 roundId)` | Returns `Round` tuple below |
| `project(uint256 roundId,uint256 projectId)` | Returns `Project` tuple below |
| `contributionOf(uint256 roundId,uint256 projectId,address account)` | Historical cumulative payment by this contributor |
| `fundingOf(uint256 roundId,address account)` | Deposited funding; zeroed only by reclaim |
| `estimateMatch(uint256 roundId,uint256 projectId)` | Match alone, including dust; live before finalize, fixed after |
| `token()` | MTCH address; use to query balance/allowance and approve |
| `roundCount()` | Enumerate round IDs in `[0, roundCount)` |

`Round` tuple order:

```text
(address creator, uint256 start, uint256 end, uint256 pool,
 uint256 projectCount, uint256 totalContributions, bool finalized, bool refundable)
```

`pool` and `totalContributions` are historical deposited totals and do not decrease on collection.
`refundable` is set only by finalization and means `Q == 0`. Before finalization it is false even
if no contribution yet exists.

`Project` tuple order:

```text
(address payout, uint256 contributions, uint256 sumSqrt, uint256 matchAmount, bool claimed)
```

`matchAmount` is zero until finalization; use `estimateMatch` before then. `contributions`,
`sumSqrt`, and `matchAmount` remain unchanged after claim. The outstanding claim is
`claimed ? 0 : contributions + matchAmount` once finalized. An empty project may make a zero
claim. Contributors and funders are not on-chain arrays, avoiding unbounded settlement loops.
The app has constant getters `MIN_DURATION`, `MAX_DURATION`, `MAX_PROJECTS`, `MIN_CONTRIBUTION`,
and `MAX_ROUND_DEPOSITS`.

## Events and discovery

| Event | Indexed fields | Other data |
| --- | --- | --- |
| `RoundCreated` | `roundId`, `creator` | `start`, `end` |
| `Funded` | `roundId`, `funder` | `amount` |
| `Registered` | `roundId`, `projectId`, `payout` | — |
| `Contributed` | `roundId`, `projectId`, `contributor` | `amount`, `contributorTotal` |
| `Finalized` | `roundId` | `pool`, `totalWeight`, `refundable` |
| `Claimed` | `roundId`, `projectId`, `payout` | `amount` (contributions + match) |
| `Reclaimed` | `roundId`, `funder` | `amount` |

Query logs in bounded block ranges from the deployment block and re-read views after confirmation.
Round/project lists can also be reconstructed directly from counts and indexed views. Use
`Funded`/`Contributed` logs for participant lists and the connected wallet's `fundingOf` and
`contributionOf` for balances. Respect chain reorganizations; an estimate is not a transaction
guarantee. No off-chain backend or indexer is required.

## Failure handling

Custom errors distinguish invalid round/project IDs, schedule/window failures, creator/payout
authorization, project cap, amount/deposit limit, and premature/duplicate settlement or collection.
`UnexpectedTransferAmount` means the token did not deliver the exact requested deposit.
SafeERC20/underlying ERC-20 errors can report failed calls, insufficient allowance, or insufficient
balance. All failures revert state and transferred funds atomically. No successful finalization
can be repeated, and a successful zero claim is still a claim. Read the ABI for exact selectors.

`round`, `project`, `contributionOf`, and `estimateMatch` reject nonexistent IDs. The public mapping
getter `fundingOf` returns zero for any nonexistent/unfunded key. Round/project fields are outputs,
not writable configuration. There is no function to enumerate all contributors or to transfer
round ownership, edit payout addresses, rescue tokens, or initialize the application.
