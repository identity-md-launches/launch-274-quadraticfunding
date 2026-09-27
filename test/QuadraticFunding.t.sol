// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FundingTestBase, Math, QuadraticFunding} from "./FundingTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract QuadraticFundingTest is FundingTestBase {
    function test_roundCreationIsPermissionlessAndEmitsConfiguration() public {
        vm.expectEmit(true, true, false, true, address(qf));
        emit QuadraticFunding.RoundCreated(1, ALICE, block.timestamp, block.timestamp + 30 days);
        vm.prank(ALICE);
        assertEq(qf.createRound(block.timestamp, block.timestamp + 30 days), 1);
        QuadraticFunding.Round memory r = qf.round(1);
        assertEq(r.creator, ALICE);
        assertEq(r.start, block.timestamp);
        assertEq(r.end, block.timestamp + 30 days);
        assertEq(r.pool, 0);
        assertFalse(r.finalized);
        assertEq(qf.roundCount(), 2);
        qf.createRound(block.timestamp, block.timestamp + 1 days);
    }

    function test_invalidSchedulesRevert() public {
        vm.expectRevert(QuadraticFunding.InvalidSchedule.selector);
        qf.createRound(block.timestamp - 1, end);
        vm.expectRevert(QuadraticFunding.InvalidSchedule.selector);
        qf.createRound(start, start);
        vm.expectRevert(QuadraticFunding.InvalidSchedule.selector);
        qf.createRound(start, start - 1);
        vm.expectRevert(QuadraticFunding.InvalidSchedule.selector);
        qf.createRound(start, start + 1 days - 1);
        vm.expectRevert(QuadraticFunding.InvalidSchedule.selector);
        qf.createRound(start, start + 30 days + 1);
    }

    function test_invalidIdsRevert() public {
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        qf.round(1);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        qf.fund(1, 1);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        qf.register(1, PAYOUT);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        qf.finalize(1);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        qf.reclaim(1);
        vm.expectRevert(QuadraticFunding.InvalidProject.selector);
        qf.project(0, 0);
        vm.expectRevert(QuadraticFunding.InvalidProject.selector);
        qf.contributionOf(0, 0, ALICE);
        vm.expectRevert(QuadraticFunding.InvalidProject.selector);
        qf.estimateMatch(0, 0);
        vm.expectRevert(QuadraticFunding.InvalidProject.selector);
        qf.contribute(0, 0, 1 ether);
        vm.expectRevert(QuadraticFunding.InvalidProject.selector);
        qf.claim(0, 0);
    }

    function test_registrationOnlyByCreatorAndNonzeroPayout() public {
        vm.expectRevert(QuadraticFunding.OnlyCreator.selector);
        vm.prank(ALICE);
        qf.register(0, ALICE);
        vm.expectRevert(QuadraticFunding.InvalidPayout.selector);
        qf.register(0, address(0));
        vm.expectEmit(true, true, true, true, address(qf));
        emit QuadraticFunding.Registered(0, 0, PAYOUT);
        assertEq(qf.register(0, PAYOUT), 0);
        assertEq(qf.project(0, 0).payout, PAYOUT);
        assertEq(qf.round(0).projectCount, 1);
    }

    function test_projectCapAndIndependentRounds() public {
        for (uint256 i; i < 50; ++i) {
            assertEq(qf.register(0, PAYOUT), i);
        }
        vm.expectRevert(QuadraticFunding.ProjectLimit.selector);
        qf.register(0, PAYOUT);
        uint256 other = qf.createRound(start, end);
        assertEq(qf.register(other, PAYOUT), 0);
        assertEq(qf.round(0).projectCount, 50);
        assertEq(qf.round(other).projectCount, 1);
    }

    function test_registerAndFundUntilLastSecond() public {
        qf.register(0, PAYOUT);
        _fund(ALICE, 1); // Funding has no 1-MTCH minimum and is allowed before start.
        vm.warp(end - 1);
        qf.register(0, ALICE);
        _fund(ALICE, 2);
        _contribute(BOB, 0, 1 ether);
        assertEq(qf.fundingOf(0, ALICE), 3);
        vm.expectRevert(QuadraticFunding.RoundStillOpen.selector);
        qf.finalize(0);
        vm.warp(end);
        vm.expectRevert(QuadraticFunding.RoundEnded.selector);
        qf.register(0, ALICE);
        vm.expectRevert(QuadraticFunding.RoundEnded.selector);
        qf.fund(0, 1);
        vm.expectRevert(QuadraticFunding.OutsideContributionWindow.selector);
        qf.contribute(0, 0, 1 ether);
        qf.finalize(0);
        vm.warp(end + 1);
        vm.expectRevert(QuadraticFunding.OutsideContributionWindow.selector);
        qf.contribute(0, 0, 1 ether);
    }

    function test_contributionWindowIncludesStartExcludesEnd() public {
        qf.register(0, PAYOUT);
        vm.warp(start - 1);
        vm.expectRevert(QuadraticFunding.OutsideContributionWindow.selector);
        qf.contribute(0, 0, 1 ether);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        vm.warp(end - 1);
        _contribute(ALICE, 0, 1 ether);
        vm.warp(end);
        vm.expectRevert(QuadraticFunding.OutsideContributionWindow.selector);
        qf.contribute(0, 0, 1 ether);
        assertEq(qf.contributionOf(0, 0, ALICE), 2 ether);
    }

    function test_minimumContributionAppliesToEveryPayment() public {
        qf.register(0, PAYOUT);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        vm.expectRevert(QuadraticFunding.InvalidAmount.selector);
        vm.prank(ALICE);
        qf.contribute(0, 0, 1 ether - 1);
        vm.expectRevert(QuadraticFunding.InvalidAmount.selector);
        qf.contribute(0, 0, 0);
        vm.expectRevert(QuadraticFunding.InvalidAmount.selector);
        qf.fund(0, 0);
    }

    function test_approveRequiredAndFailedPaymentRollsBackAllAccounting() public {
        qf.register(0, PAYOUT);
        vm.warp(start);
        vm.prank(ALICE);
        mtch.approve(address(qf), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(qf), 0, 1 ether)
        );
        vm.prank(ALICE);
        qf.contribute(0, 0, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(qf), 0, 1 ether)
        );
        vm.prank(ALICE);
        qf.fund(0, 1 ether);
        assertEq(qf.project(0, 0).contributions, 0);
        assertEq(qf.project(0, 0).sumSqrt, 0);
        assertEq(qf.contributionOf(0, 0, ALICE), 0);
        assertEq(qf.round(0).pool, 0);
        assertEq(qf.round(0).totalContributions, 0);
        assertEq(qf.fundingOf(0, ALICE), 0);
        assertEq(mtch.balanceOf(address(qf)), 0);
    }

    function test_depositEventsAndIncrementalSqrt() public {
        qf.register(0, PAYOUT);
        vm.expectEmit(true, true, false, true, address(qf));
        emit QuadraticFunding.Funded(0, ALICE, 17);
        _fund(ALICE, 17);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        vm.expectEmit(true, true, true, true, address(qf));
        emit QuadraticFunding.Contributed(0, 0, ALICE, 3 ether, 4 ether);
        _contribute(ALICE, 0, 3 ether);
        _contribute(BOB, 0, 9 ether);
        assertEq(qf.project(0, 0).sumSqrt, 5e9);
        assertEq(qf.project(0, 0).contributions, 13 ether);
        assertEq(qf.round(0).totalContributions, 13 ether);
    }

    function testFuzz_incrementalSqrtEqualsRecomputation(uint128[9] memory values) public {
        qf.register(0, PAYOUT);
        vm.warp(start);
        address[3] memory people = [ALICE, BOB, CAROL];
        uint256[3] memory totals;
        for (uint256 i; i < values.length; ++i) {
            uint256 amount = bound(values[i], 1 ether, 100_000 ether);
            uint256 person = i % 3;
            _contribute(people[person], 0, amount);
            totals[person] += amount;
            uint256 expected;
            uint256 total;
            for (uint256 j; j < people.length; ++j) {
                expected += Math.sqrt(totals[j]);
                total += totals[j];
                assertEq(qf.contributionOf(0, 0, people[j]), totals[j]);
            }
            assertEq(qf.project(0, 0).sumSqrt, expected);
            assertEq(qf.project(0, 0).contributions, total);
        }
    }

    function test_knownQuadraticAllocationAndClaims() public {
        qf.register(0, ALICE);
        qf.register(0, BOB);
        _fund(CAROL, 100 ether);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        _contribute(BOB, 0, 1 ether); // q_0 = (1e9 + 1e9)^2 = 4e18.
        _contribute(CAROL, 1, 1 ether); // q_1 = 1e18.
        assertEq(qf.estimateMatch(0, 0), 80 ether);
        assertEq(qf.estimateMatch(0, 1), 20 ether);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(qf));
        emit QuadraticFunding.Finalized(0, 100 ether, 5 ether, false);
        qf.finalize(0);
        uint256 beforeAlice = mtch.balanceOf(ALICE);
        vm.expectEmit(true, true, true, true, address(qf));
        emit QuadraticFunding.Claimed(0, 0, ALICE, 82 ether);
        vm.prank(ALICE);
        qf.claim(0, 0);
        assertEq(mtch.balanceOf(ALICE), beforeAlice + 82 ether);
        vm.prank(BOB);
        qf.claim(0, 1);
        assertEq(mtch.balanceOf(address(qf)), 0);
        assertEq(qf.estimateMatch(0, 0), 80 ether);
        assertTrue(qf.project(0, 0).claimed);
    }

    function test_dustGoesToLargestWeightLowestIdOnTie() public {
        for (uint256 i; i < 3; ++i) {
            qf.register(0, PAYOUT);
        }
        _fund(CAROL, 2);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        _contribute(ALICE, 1, 4 ether);
        _contribute(ALICE, 2, 4 ether);
        // Floor(2 * weight/9) is zero for every project; id 1 wins the 4:4 tie.
        assertEq(qf.estimateMatch(0, 0), 0);
        assertEq(qf.estimateMatch(0, 1), 2);
        assertEq(qf.estimateMatch(0, 2), 0);
        _finish();
        assertEq(qf.project(0, 1).matchAmount, 2);
    }

    function testFuzz_wholePoolDistributedExactlyAndClaimsConserveFunds(uint128[18] memory values, uint128 poolSeed)
        public
    {
        for (uint256 i; i < 6; ++i) {
            qf.register(0, PAYOUT);
        }
        uint256 pool = bound(poolSeed, 0, 1_000_000 ether);
        if (pool > 0) _fund(CAROL, pool);
        vm.warp(start);
        address[3] memory people = [ALICE, BOB, CAROL];
        uint256[6] memory roots;
        uint256 contributions;
        for (uint256 i; i < values.length; ++i) {
            uint256 amount = bound(values[i], 1 ether, 100_000 ether);
            uint256 pid = i % 6;
            _contribute(people[i / 6], pid, amount);
            roots[pid] += Math.sqrt(amount);
            contributions += amount;
        }
        uint256[6] memory weights;
        uint256[6] memory estimates;
        uint256 totalWeight;
        uint256 largest;
        for (uint256 i; i < 6; ++i) {
            weights[i] = roots[i] * roots[i];
            totalWeight += weights[i];
            if (weights[i] > weights[largest]) largest = i;
            estimates[i] = qf.estimateMatch(0, i);
        }
        _finish();
        uint256 distributed;
        uint256 ordinaryAllocations;
        for (uint256 i; i < 6; ++i) {
            uint256 actual = qf.project(0, i).matchAmount;
            uint256 floored = pool * weights[i] / totalWeight; // Bounded product; independent of mulDiv.
            ordinaryAllocations += floored;
            if (i != largest) assertEq(actual, floored);
            assertEq(actual, estimates[i]);
            distributed += actual;
            vm.prank(PAYOUT);
            qf.claim(0, i);
        }
        assertEq(qf.project(0, largest).matchAmount, pool * weights[largest] / totalWeight + pool - ordinaryAllocations);
        assertEq(distributed, pool);
        assertEq(mtch.balanceOf(PAYOUT), pool + contributions);
        assertEq(mtch.balanceOf(address(qf)), 0);
    }

    function test_zeroWeightReclaimsEachFundersAccumulatedDeposits() public {
        qf.register(0, PAYOUT);
        _fund(ALICE, 5 ether);
        _fund(ALICE, 7 ether);
        _fund(BOB, 9 ether);
        assertEq(qf.estimateMatch(0, 0), 0);
        vm.expectRevert(QuadraticFunding.NotFinalized.selector);
        vm.prank(ALICE);
        qf.reclaim(0);
        _finish();
        assertTrue(qf.round(0).refundable);
        assertEq(qf.project(0, 0).matchAmount, 0);
        vm.expectRevert(QuadraticFunding.NothingToReclaim.selector);
        vm.prank(CAROL);
        qf.reclaim(0);
        vm.expectEmit(true, true, false, true, address(qf));
        emit QuadraticFunding.Reclaimed(0, ALICE, 12 ether);
        vm.prank(ALICE);
        qf.reclaim(0);
        assertEq(qf.fundingOf(0, ALICE), 0);
        assertEq(mtch.balanceOf(ALICE), 10_000_000 ether);
        vm.expectRevert(QuadraticFunding.NothingToReclaim.selector);
        vm.prank(ALICE);
        qf.reclaim(0);
        vm.prank(BOB);
        qf.reclaim(0);
        assertEq(mtch.balanceOf(BOB), 10_000_000 ether);
        assertEq(mtch.balanceOf(address(qf)), 0);
        vm.prank(PAYOUT);
        qf.claim(0, 0); // An empty project has a harmless, one-time zero claim.
        assertTrue(qf.project(0, 0).claimed);
    }

    function test_roundWithoutProjectsRefundsAndEmptyRoundFinalizes() public {
        _fund(ALICE, 1 ether);
        qf.createRound(start, end);
        _finish();
        vm.prank(ALICE);
        qf.reclaim(0);
        qf.finalize(1);
        assertTrue(qf.round(1).refundable);
        assertEq(mtch.balanceOf(address(qf)), 0);
    }

    function test_claimRequiresFinalizationPayoutAndCanHappenOnlyOnce() public {
        qf.register(0, PAYOUT);
        vm.warp(start);
        _contribute(ALICE, 0, 1 ether);
        vm.expectRevert(QuadraticFunding.NotFinalized.selector);
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        _finish();
        vm.expectRevert(QuadraticFunding.OnlyPayout.selector);
        qf.claim(0, 0);
        vm.expectRevert(QuadraticFunding.OnlyPayout.selector);
        vm.prank(ALICE);
        qf.claim(0, 0);
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        vm.expectRevert(QuadraticFunding.AlreadyClaimed.selector);
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        vm.expectRevert(QuadraticFunding.AlreadyFinalized.selector);
        qf.finalize(0);
    }

    function test_funderCannotReclaimPoolWhenContributionsExist() public {
        qf.register(0, PAYOUT);
        _fund(ALICE, 100 ether);
        vm.warp(start);
        _contribute(BOB, 0, 1 ether);
        _finish();
        vm.expectRevert(QuadraticFunding.NotRefundable.selector);
        vm.prank(ALICE);
        qf.reclaim(0);
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        assertEq(mtch.balanceOf(PAYOUT), 101 ether);
    }

    function test_zeroPoolAndZeroWeightProject() public {
        qf.register(0, PAYOUT);
        qf.register(0, ALICE);
        vm.warp(start);
        _contribute(BOB, 0, 3 ether);
        _finish();
        assertFalse(qf.round(0).refundable);
        assertEq(qf.project(0, 0).matchAmount, 0);
        vm.prank(ALICE);
        qf.claim(0, 1);
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        assertEq(mtch.balanceOf(PAYOUT), 3 ether);
    }

    function test_balancesAndClaimsIsolatedAcrossRounds() public {
        qf.register(0, PAYOUT);
        qf.createRound(start, end + 1 days);
        qf.register(1, ALICE);
        _fund(ALICE, 100 ether);
        qf.fund(1, 50 ether);
        vm.warp(start);
        _contribute(BOB, 0, 1 ether);
        qf.contribute(1, 0, 2 ether);
        _finish();
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        assertEq(mtch.balanceOf(address(qf)), 52 ether);
        vm.warp(end + 1 days);
        qf.finalize(1);
        vm.prank(ALICE);
        qf.claim(1, 0);
        assertEq(mtch.balanceOf(address(qf)), 0);
    }

    function test_donationsDoNotChangeAccountingOrBecomeSweepable() public {
        mtch.transfer(address(qf), 3 ether);
        qf.register(0, PAYOUT);
        _fund(ALICE, 10 ether);
        vm.warp(start);
        _contribute(BOB, 0, 1 ether);
        _finish();
        vm.prank(PAYOUT);
        qf.claim(0, 0);
        assertEq(mtch.balanceOf(PAYOUT), 11 ether);
        assertEq(mtch.balanceOf(address(qf)), 3 ether);
    }

    function test_sybilSplittingRaisesWeightWhileRepeatedPaymentsDoNot() public {
        qf.register(0, PAYOUT);
        qf.register(0, PAYOUT);
        _fund(CAROL, 100 ether);
        vm.warp(start);
        _contribute(ALICE, 0, 2 ether);
        _contribute(ALICE, 0, 2 ether);
        _contribute(BOB, 1, 2 ether);
        _contribute(CAROL, 1, 2 ether);
        assertEq(qf.project(0, 0).sumSqrt, Math.sqrt(4 ether));
        assertEq(qf.project(0, 1).sumSqrt, 2 * Math.sqrt(2 ether));
        assertGt(qf.estimateMatch(0, 1), qf.estimateMatch(0, 0));
    }

    function test_rejectsNativeETHAndUnknownCalls() public {
        vm.deal(address(this), 2 ether);
        (bool receiveAccepted,) = address(qf).call{value: 1 ether}("");
        assertFalse(receiveAccepted);
        (bool payableAccepted,) = address(qf).call{value: 1 ether}(abi.encodeCall(qf.fund, (0, 1)));
        assertFalse(payableAccepted);
        (bool unknownAccepted,) = address(qf).call(hex"deadbeef");
        assertFalse(unknownAccepted);
        assertEq(address(qf).balance, 0);
    }
}

contract MathEdgeTest is FundingTestBase {
    function test_integerSqrtEdges() public pure {
        assertEq(Math.sqrt(0), 0);
        assertEq(Math.sqrt(1), 1);
        assertEq(Math.sqrt(2), 1);
        assertEq(Math.sqrt(3), 1);
        assertEq(Math.sqrt(4), 2);
        assertEq(Math.sqrt(8), 2);
        assertEq(Math.sqrt(9), 3);
        assertEq(Math.sqrt(1 ether - 1), 1e9 - 1);
        assertEq(Math.sqrt(1 ether), 1e9);
        assertEq(Math.sqrt(1 ether + 1), 1e9);
        assertEq(Math.sqrt(type(uint256).max), type(uint128).max);
        uint256 largestRoot = type(uint128).max;
        uint256 largestSquare = largestRoot * largestRoot;
        assertEq(Math.sqrt(largestSquare - 1), largestRoot - 1);
        assertEq(Math.sqrt(largestSquare), largestRoot);
        assertEq(Math.sqrt(largestSquare + 1), largestRoot);
    }

    function testFuzz_sqrtFloorDefinition(uint256 value) public pure {
        uint256 root = Math.sqrt(value);
        if (value == 0) assertEq(root, 0);
        else assertLe(root, value / root);
        uint256 next = root + 1;
        assertGt(next, value / next);
    }

    function test_fullSupplyCanBeSettledWithoutArithmeticOverflow() public {
        vm.prank(ALICE);
        mtch.transfer(address(this), 10_000_000 ether);
        vm.prank(BOB);
        mtch.transfer(address(this), 10_000_000 ether);
        vm.prank(CAROL);
        mtch.transfer(address(this), 10_000_000 ether);
        for (uint256 i; i < 50; ++i) {
            qf.register(0, PAYOUT);
        }
        uint256 pool = 5e26;
        qf.fund(0, pool);
        vm.warp(start);
        for (uint256 i; i < 50; ++i) {
            qf.contribute(0, i, 1e25);
        }
        assertEq(mtch.balanceOf(address(qf)), 1e27);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.fund(0, type(uint256).max);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.contribute(0, 0, type(uint256).max);
        _finish();
        uint256 matched;
        for (uint256 i; i < 50; ++i) {
            matched += qf.project(0, i).matchAmount;
            vm.prank(PAYOUT);
            qf.claim(0, i);
        }
        assertEq(matched, pool);
        assertEq(mtch.balanceOf(PAYOUT), 1e27);
        assertEq(mtch.balanceOf(address(qf)), 0);
    }
}
