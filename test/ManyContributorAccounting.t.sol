// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";

/// @dev Independent ledgers record successful inputs, never values read from the application.
/// Deposits use real fixed-supply MTCH transfers. Unsolicited ERC-20 donations are outside these
/// action sequences: before settlement pools are pending; afterwards they are matches or refunds.
contract ManyContributorAccountingTest is Test {
    struct ModelProject {
        uint256 contributions;
        uint256 matching;
        bool claimed;
    }

    struct ModelRound {
        uint256 pool;
        uint256 contributions;
        bool finalized;
        bool refundable;
        ModelProject[] projects;
        uint256[] funding;
    }

    LaunchToken private token;
    QuadraticFunding private qf;
    ModelRound[] private rounds;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) private paid;
    uint256 private actors;
    uint256 private start;
    uint256 private totalIn;
    uint256 private totalOut;
    address private constant STRANGER = address(0xBAD);

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        qf = new QuadraticFunding(address(token));
        start = block.timestamp + 1 days;
    }

    function testFuzz_manyContributorsAndProjectsSettleExactly(
        uint256 seed,
        uint8 actorSeed,
        uint8 projectSeed,
        uint8 activeSeed,
        uint96 poolSeed
    ) public {
        actors = bound(actorSeed, 1, 32);
        uint256 count = bound(projectSeed, 1, 50);
        uint256 active = bound(activeSeed, 1, count);
        _create(count, start + 1 days);
        uint256 pool = bound(poolSeed, 0, 1e26);
        for (uint256 who; who < actors; ++who) {
            _fund(0, who, pool / actors + (who == 0 ? pool % actors : 0));
        }

        _reject(
            QuadraticFunding.OutsideContributionWindow.selector,
            _actor(0),
            abi.encodeCall(qf.contribute, (0, 0, 1 ether))
        );
        _reject(QuadraticFunding.OnlyCreator.selector, STRANGER, abi.encodeCall(qf.register, (0, STRANGER)));
        _reject(QuadraticFunding.NotFinalized.selector, _actor(0), abi.encodeCall(qf.claim, (0, 0)));
        _reject(QuadraticFunding.NotFinalized.selector, _actor(0), abi.encodeCall(qf.reclaim, (0)));

        vm.warp(start);
        _populate(0, active, seed);
        _assertAll();
        vm.warp(qf.round(0).end - 1);
        _reject(QuadraticFunding.RoundStillOpen.selector, STRANGER, abi.encodeCall(qf.finalize, (0)));
        vm.warp(qf.round(0).end);
        _reject(
            QuadraticFunding.OutsideContributionWindow.selector,
            _actor(0),
            abi.encodeCall(qf.contribute, (0, 0, 1 ether))
        );
        _reject(QuadraticFunding.RoundEnded.selector, _actor(0), abi.encodeCall(qf.fund, (0, 1)));
        _finalize(0);
        _reject(QuadraticFunding.AlreadyFinalized.selector, STRANGER, abi.encodeCall(qf.finalize, (0)));
        _reject(QuadraticFunding.NotRefundable.selector, _actor(0), abi.encodeCall(qf.reclaim, (0)));
        _reject(QuadraticFunding.OnlyPayout.selector, STRANGER, abi.encodeCall(qf.claim, (0, 0)));

        uint256[] memory order = _permutation(count, seed);
        for (uint256 i; i < count; ++i) {
            _claim(0, order[i]);
        }
        _assertAll();
        assertEq(token.balanceOf(address(qf)), 0, "all entitlements collectable");
        assertEq(totalIn, totalOut);
    }

    function testFuzz_mixedRoundsConservePendingMatchesAndRefunds(uint256 seed, uint8 actorSeed, uint8 projectSeed)
        public
    {
        actors = bound(actorSeed, 2, 32);
        uint256 count = bound(projectSeed, 1, 12);
        _create(count, start + 1 days);
        _create(seed % 51, start + 1 days); // Includes both no projects and registered-but-empty projects.
        _create(count, start + 2 days);
        for (uint256 who; who < actors; ++who) {
            _fund(0, who, 1 + _random(seed, who) % 100 ether);
            _fund(1, who, 1 + _random(seed, who + 32) % 100 ether);
            _fund(1, who, 1 + _random(seed, who + 64) % 100 ether); // Accumulated refunds.
            _fund(2, who, 1 + _random(seed, who + 96) % 100 ether);
        }
        vm.warp(start);
        _populate(0, count, seed);
        _populate(2, count, _random(seed, 128));
        _assertAll();
        vm.warp(start + 1 days);
        uint256 first = seed % 2;
        _finalize(first);
        _finalize(1 - first);
        _reject(QuadraticFunding.NothingToReclaim.selector, STRANGER, abi.encodeCall(qf.reclaim, (1)));
        _reject(QuadraticFunding.NotRefundable.selector, _actor(0), abi.encodeCall(qf.reclaim, (0)));

        uint256[] memory claims = _permutation(count, seed);
        uint256[] memory refunds = _permutation(actors, _random(seed, 129));
        uint256 steps = count > actors ? count : actors;
        for (uint256 i; i < steps; ++i) {
            if (i < count) _claim(0, claims[i]);
            if (i < actors) _reclaim(1, refunds[i]);
            // A still-open round must remain fully backed while the others pay out.
            _contribute(2, i % count, i % actors, _amount(seed, i + 256));
            _fund(2, i % actors, i + 1);
        }
        for (uint256 pid; pid < rounds[1].projects.length; ++pid) {
            _claim(1, pid);
        }
        _assertAll();
        vm.warp(start + 2 days);
        _finalize(2);
        for (uint256 i; i < count; ++i) {
            _claim(2, claims[count - 1 - i]);
        }
        _assertAll();
        assertEq(token.balanceOf(address(qf)), 0);
        assertEq(totalIn, totalOut);
    }

    function testFuzz_failedPaymentsPreserveExistingContributionsAndFunding(uint128 amountSeed, uint8 actorSeed)
        public
    {
        actors = 8;
        uint256 who = bound(actorSeed, 0, actors - 1);
        uint256 amount = bound(amountSeed, 1 ether, 1_000 ether);
        _create(3, start + 1 days);
        _fund(0, who, amount);
        vm.warp(start);
        _contribute(0, 0, who, amount);
        _contribute(0, 1, (who + 1) % actors, 1 ether);
        _provide(who, amount);
        _reject(QuadraticFunding.InvalidAmount.selector, _actor(who), abi.encodeCall(qf.fund, (0, 0)));
        _reject(
            QuadraticFunding.InvalidAmount.selector,
            _actor(who),
            abi.encodeCall(qf.contribute, (0, 0, uint256(amountSeed) % 1 ether))
        );
        _reject(QuadraticFunding.InvalidProject.selector, _actor(who), abi.encodeCall(qf.contribute, (0, 3, amount)));
        _reject(QuadraticFunding.InvalidRound.selector, _actor(who), abi.encodeCall(qf.fund, (1, amount)));

        vm.prank(_actor(who));
        token.approve(address(qf), amount - 1);
        bytes memory allowanceError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(qf), amount - 1, amount);
        _rejectData(allowanceError, _actor(who), abi.encodeCall(qf.contribute, (0, 0, amount)));
        _rejectData(allowanceError, _actor(who), abi.encodeCall(qf.fund, (0, amount)));
        assertEq(token.allowance(_actor(who), address(qf)), amount - 1);
        _assertAll();

        vm.startPrank(_actor(who));
        token.approve(address(qf), amount);
        token.transfer(address(this), token.balanceOf(_actor(who)));
        vm.stopPrank();
        bytes memory balanceError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _actor(who), 0, amount);
        _rejectData(balanceError, _actor(who), abi.encodeCall(qf.contribute, (0, 0, amount)));
        _rejectData(balanceError, _actor(who), abi.encodeCall(qf.fund, (0, amount)));
        assertEq(token.allowance(_actor(who), address(qf)), amount, "failed transfer must restore spent allowance");
        _assertAll();
        _contribute(0, 0, who, amount); // A valid retry still accumulates from the last successful deposit.
        _fund(0, who, amount);
        vm.warp(start + 1 days);
        _finalize(0);
        for (uint256 pid; pid < 3; ++pid) {
            _claim(0, pid);
        }
        _assertAll();
        assertEq(totalIn, totalOut);
    }

    function testFuzz_incrementalRootsAroundPerfectSquares(uint64 rootSeed) public {
        actors = 2;
        uint256 root = bound(rootSeed, 1e9 + 1, 1e12);
        uint256 nextRoot = root + 1e9;
        _create(3, start + 1 days);
        _fund(0, 1, 7);
        vm.warp(start);
        for (uint256 pid; pid < 3; ++pid) {
            uint256 first = root * root - 1 + pid;
            uint256 cumulative = nextRoot * nextRoot - 1 + pid;
            _contribute(0, pid, 0, first);
            assertEq(qf.project(0, pid).sumSqrt, pid == 0 ? root - 1 : root);
            _contribute(0, pid, 1, 1 ether);
            _contribute(0, pid, 0, cumulative - first);
            assertEq(qf.project(0, pid).sumSqrt, (pid == 0 ? nextRoot - 1 : nextRoot) + 1e9);
        }
        vm.warp(start + 1 days);
        _finalize(0);
        for (uint256 pid; pid < 3; ++pid) {
            _claim(0, pid);
        }
        _assertAll();
    }

    function test_fiftyProjectsThirtyTwoContributorsAndOneUnitPool() public {
        actors = 32;
        _create(50, start + 1 days);
        _reject(QuadraticFunding.ProjectLimit.selector, address(this), abi.encodeCall(qf.register, (0, _actor(0))));
        _fund(0, 0, 1);
        vm.warp(start);
        for (uint256 who; who < actors; ++who) {
            _contribute(0, 1, who, 1 ether);
            _contribute(0, 49, who, 1 ether);
        }
        vm.warp(start + 1 days);
        _finalize(0);
        assertEq(qf.project(0, 1).sumSqrt, 32e9);
        assertEq(qf.project(0, 1).matchAmount, 1, "lowest id wins the largest-weight tie");
        assertEq(qf.project(0, 49).matchAmount, 0);
        for (uint256 pid = 50; pid > 0; --pid) {
            _claim(0, pid - 1);
        }
        _assertAll();
        assertEq(totalIn, totalOut);
    }

    function _create(uint256 count, uint256 end) private {
        uint256 rid = rounds.length;
        assertEq(qf.createRound(start, end), rid);
        ModelRound storage r = rounds.push();
        for (uint256 who; who < actors; ++who) {
            r.funding.push(0);
        }
        for (uint256 pid; pid < count; ++pid) {
            assertEq(qf.register(rid, _actor(pid % actors)), pid);
            r.projects.push();
        }
    }

    function _provide(uint256 who, uint256 amount) private {
        token.transfer(_actor(who), amount);
        vm.prank(_actor(who));
        token.approve(address(qf), type(uint256).max);
    }

    function _fund(uint256 rid, uint256 who, uint256 amount) private {
        if (amount == 0) return; // A zero pool needs no deposit; zero fund calls are tested separately.
        _provide(who, amount);
        vm.prank(_actor(who));
        qf.fund(rid, amount);
        rounds[rid].pool += amount;
        rounds[rid].funding[who] += amount;
        totalIn += amount;
        assertEq(qf.fundingOf(rid, _actor(who)), rounds[rid].funding[who]);
        _assertCustody();
    }

    function _contribute(uint256 rid, uint256 pid, uint256 who, uint256 amount) private {
        _provide(who, amount);
        vm.prank(_actor(who));
        qf.contribute(rid, pid, amount);
        paid[rid][pid][who] += amount;
        rounds[rid].projects[pid].contributions += amount;
        rounds[rid].contributions += amount;
        totalIn += amount;
        _assertProject(rid, pid);
        _assertCustody();
    }

    function _populate(uint256 rid, uint256 active, uint256 seed) private {
        // Every actor and every active project participates. Each pair gets a repeated payment,
        // while untouched registered projects exercise zero weights beside nonzero weights.
        for (uint256 i; i < actors + active; ++i) {
            _contribute(rid, i % active, i % actors, _amount(seed, 2 * i));
            _contribute(rid, i % active, i % actors, _amount(seed, 2 * i + 1));
        }
    }

    function _finalize(uint256 rid) private {
        ModelRound storage r = rounds[rid];
        uint256[] memory weights = new uint256[](r.projects.length);
        uint256 totalWeight;
        uint256 winner;
        for (uint256 pid; pid < weights.length; ++pid) {
            uint256 rootSum = _rootSum(rid, pid);
            weights[pid] = rootSum * rootSum;
            totalWeight += weights[pid];
            if (weights[pid] > weights[winner]) winner = pid;
        }
        r.refundable = totalWeight == 0;
        if (totalWeight != 0) {
            uint256 floored;
            for (uint256 pid; pid < weights.length; ++pid) {
                // At most 32 contributors and the real 1e27 supply keep this product below 2^256.
                // Plain division is independent of the application's Math.mulDiv implementation.
                r.projects[pid].matching = r.pool * weights[pid] / totalWeight;
                floored += r.projects[pid].matching;
            }
            r.projects[winner].matching += r.pool - floored;
        }
        for (uint256 pid; pid < weights.length; ++pid) {
            assertEq(qf.estimateMatch(rid, pid), r.projects[pid].matching, "live allocation");
        }
        vm.prank(STRANGER); // Neither creator, contributor, funder nor payout.
        qf.finalize(rid);
        r.finalized = true;
        _assertAll();
    }

    function _claim(uint256 rid, uint256 pid) private {
        ModelProject storage p = rounds[rid].projects[pid];
        address recipient = _actor(pid % actors);
        uint256 beforeBalance = token.balanceOf(recipient);
        uint256 amount = p.contributions + p.matching;
        vm.prank(recipient);
        qf.claim(rid, pid);
        p.claimed = true;
        totalOut += amount;
        assertEq(token.balanceOf(recipient), beforeBalance + amount, "exact project payout");
        assertTrue(qf.project(rid, pid).claimed);
        assertEq(qf.estimateMatch(rid, pid), p.matching, "claim cannot change allocation");
        _reject(QuadraticFunding.AlreadyClaimed.selector, recipient, abi.encodeCall(qf.claim, (rid, pid)));
        _assertCustody();
    }

    function _reclaim(uint256 rid, uint256 who) private {
        uint256 amount = rounds[rid].funding[who];
        assertGt(amount, 0, "exercise an actual refund");
        uint256 beforeBalance = token.balanceOf(_actor(who));
        vm.prank(_actor(who));
        qf.reclaim(rid);
        rounds[rid].funding[who] = 0;
        totalOut += amount;
        assertEq(token.balanceOf(_actor(who)), beforeBalance + amount, "exact funder refund");
        assertEq(qf.fundingOf(rid, _actor(who)), 0);
        _reject(QuadraticFunding.NothingToReclaim.selector, _actor(who), abi.encodeCall(qf.reclaim, (rid)));
        _assertCustody();
    }

    function _assertCustody() private view {
        uint256 contributions;
        uint256 matches;
        uint256 reclaimable;
        uint256 pendingPools;
        for (uint256 rid; rid < rounds.length; ++rid) {
            ModelRound storage r = rounds[rid];
            if (!r.finalized) {
                pendingPools += r.pool;
            } else if (r.refundable) {
                for (uint256 who; who < actors; ++who) {
                    reclaimable += r.funding[who];
                }
            }
            for (uint256 pid; pid < r.projects.length; ++pid) {
                ModelProject storage p = r.projects[pid];
                if (!p.claimed) {
                    contributions += p.contributions;
                    if (r.finalized) matches += p.matching;
                }
            }
        }
        assertEq(
            token.balanceOf(address(qf)),
            contributions + matches + reclaimable + pendingPools,
            "MTCH held equals independent unpaid liabilities"
        );
        assertEq(token.balanceOf(address(qf)), totalIn - totalOut, "cash flow conservation");
        assertEq(token.totalSupply(), 1e27);
    }

    function _assertAll() private view {
        assertEq(qf.roundCount(), rounds.length);
        for (uint256 rid; rid < rounds.length; ++rid) {
            ModelRound storage expected = rounds[rid];
            QuadraticFunding.Round memory actual = qf.round(rid);
            assertEq(actual.pool, expected.pool);
            assertEq(actual.totalContributions, expected.contributions);
            assertEq(actual.projectCount, expected.projects.length);
            assertEq(actual.finalized, expected.finalized);
            assertEq(actual.refundable, expected.refundable);
            uint256 matches;
            for (uint256 pid; pid < expected.projects.length; ++pid) {
                _assertProject(rid, pid);
                matches += qf.project(rid, pid).matchAmount;
            }
            // Q == 0 has refund liabilities, so sum(matches) is zero even with a nonzero pool.
            assertEq(matches, expected.finalized && !expected.refundable ? expected.pool : 0, "exact pool allocation");
            for (uint256 who; who < actors; ++who) {
                assertEq(qf.fundingOf(rid, _actor(who)), expected.funding[who]);
            }
        }
        _assertCustody();
    }

    function _assertProject(uint256 rid, uint256 pid) private view {
        QuadraticFunding.Project memory p = qf.project(rid, pid);
        ModelProject storage expected = rounds[rid].projects[pid];
        assertEq(p.payout, _actor(pid % actors));
        assertEq(p.contributions, expected.contributions);
        assertEq(p.matchAmount, expected.matching);
        assertEq(p.claimed, expected.claimed);
        assertEq(p.sumSqrt, _rootSum(rid, pid), "recomputed floor roots after every payment");
        for (uint256 who; who < actors; ++who) {
            assertEq(qf.contributionOf(rid, pid, _actor(who)), paid[rid][pid][who]);
        }
    }

    function _rootSum(uint256 rid, uint256 pid) private view returns (uint256 sum) {
        for (uint256 who; who < actors; ++who) {
            sum += _sqrt(paid[rid][pid][who]);
        }
    }

    /// @dev Babylonian iteration, independent of OZ's bit-based initial estimate and fixed steps.
    function _sqrt(uint256 value) private pure returns (uint256 root) {
        if (value == 0) return 0;
        root = value;
        uint256 next = value / 2 + value % 2;
        while (next < root) {
            root = next;
            next = (root + value / root) / 2;
        }
        // All nonzero inputs are legal contributions >= 1e18 and bounded by the real supply.
        assertLe(root, value / root);
        assertGt(root + 1, value / (root + 1));
    }

    function _reject(bytes4 selector, address caller, bytes memory data) private {
        _rejectData(abi.encodeWithSelector(selector), caller, data);
    }

    function _rejectData(bytes memory expected, address caller, bytes memory data) private {
        uint256 held = token.balanceOf(address(qf));
        uint256 callerBalance = token.balanceOf(caller);
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(qf).call(data);
        assertFalse(ok, "invalid action succeeded");
        assertEq(reason, expected, "precise failure path");
        assertEq(token.balanceOf(address(qf)), held, "failed action changed custody");
        assertEq(token.balanceOf(caller), callerBalance, "failed action changed caller balance");
        _assertCustody();
    }

    function _actor(uint256 who) private pure returns (address) {
        return address(uint160(0x10000 + who));
    }

    function _random(uint256 seed, uint256 salt) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _amount(uint256 seed, uint256 salt) private pure returns (uint256) {
        uint256 sample = _random(seed, salt);
        if (sample % 4 == 0) return 1 ether + sample % (999 ether + 1);
        uint256 root = 1e9 + 1 + (sample >> 8) % 29e9;
        return root * root + sample % 4 - 2; // Adjacent to and exactly on a perfect square.
    }

    function _permutation(uint256 length, uint256 seed) private pure returns (uint256[] memory order) {
        order = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            order[i] = i;
        }
        for (uint256 remaining = length; remaining > 1; --remaining) {
            uint256 j = _random(seed, remaining) % remaining;
            (order[remaining - 1], order[j]) = (order[j], order[remaining - 1]);
        }
    }
}
