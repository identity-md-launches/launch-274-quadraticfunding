// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FundingHandler is Test {
    LaunchToken public immutable token;
    QuadraticFunding public immutable qf;
    uint256 public totalIn;
    uint256 public totalOut;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public contributed;

    constructor(LaunchToken token_, QuadraticFunding qf_) {
        token = token_;
        qf = qf_;
        for (uint256 a; a < 4; ++a) {
            vm.prank(actor(a));
            token.approve(address(qf), type(uint256).max);
        }
    }

    function actor(uint256 id) public pure returns (address) {
        return address(uint160(0x1000 + id));
    }

    function fund(uint256 rid, uint256 who, uint256 amount) external {
        rid %= 3;
        who %= 4;
        if (block.timestamp >= qf.round(rid).end) return;
        amount = bound(amount, 1, 1_000 ether);
        vm.prank(actor(who));
        qf.fund(rid, amount);
        totalIn += amount;
    }

    function contribute(uint256 rid, uint256 pid, uint256 who, uint256 amount) external {
        rid %= 3;
        pid %= 5;
        who %= 4;
        if (block.timestamp >= qf.round(rid).end) return;
        amount = bound(amount, 1 ether, 1_000 ether);
        vm.prank(actor(who));
        qf.contribute(rid, pid, amount);
        contributed[rid][pid][who] += amount;
        totalIn += amount;
    }

    function advance(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 6 hours));
    }

    function finalize(uint256 rid) public {
        rid %= 3;
        QuadraticFunding.Round memory r = qf.round(rid);
        if (r.finalized || block.timestamp < r.end) return;
        qf.finalize(rid);
    }

    function claim(uint256 rid, uint256 pid) public {
        rid %= 3;
        pid %= 5;
        if (!qf.round(rid).finalized) return;
        QuadraticFunding.Project memory p = qf.project(rid, pid);
        if (p.claimed) return;
        vm.prank(p.payout);
        qf.claim(rid, pid);
        totalOut += p.contributions + p.matchAmount;
    }

    function reclaim(uint256 rid, uint256 who) public {
        rid %= 3;
        who %= 4;
        if (!qf.round(rid).refundable) return;
        uint256 amount = qf.fundingOf(rid, actor(who));
        if (amount == 0) return;
        vm.prank(actor(who));
        qf.reclaim(rid);
        totalOut += amount;
    }

    function settleAll() external {
        uint256 lastEnd = qf.round(2).end;
        if (block.timestamp < lastEnd) vm.warp(lastEnd);
        for (uint256 rid; rid < 3; ++rid) {
            finalize(rid);
            for (uint256 pid; pid < 5; ++pid) {
                claim(rid, pid);
            }
            for (uint256 who; who < 4; ++who) {
                reclaim(rid, who);
            }
        }
    }
}

contract ConservationInvariantTest is Test {
    LaunchToken internal token;
    QuadraticFunding internal qf;
    FundingHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        qf = new QuadraticFunding(address(token));
        handler = new FundingHandler(token, qf);
        for (uint256 who; who < 4; ++who) {
            token.transfer(handler.actor(who), 100_000_000 ether);
        }
        for (uint256 rid; rid < 3; ++rid) {
            qf.createRound(block.timestamp, block.timestamp + (rid + 1) * 1 days);
            for (uint256 pid; pid < 5; ++pid) {
                qf.register(rid, handler.actor(pid % 4));
            }
        }
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.contribute.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.reclaim.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balanceEqualsUnpaidLiabilitiesAndIncrementalWeightsMatch() public view {
        uint256 liabilities;
        for (uint256 rid; rid < 3; ++rid) {
            QuadraticFunding.Round memory r = qf.round(rid);
            uint256 totalMatch;
            uint256 totalContributions;
            for (uint256 pid; pid < 5; ++pid) {
                QuadraticFunding.Project memory p = qf.project(rid, pid);
                uint256 expectedRootSum;
                uint256 expectedContributions;
                for (uint256 who; who < 4; ++who) {
                    uint256 paid = handler.contributed(rid, pid, who);
                    assertEq(qf.contributionOf(rid, pid, handler.actor(who)), paid);
                    expectedRootSum += Math.sqrt(paid);
                    expectedContributions += paid;
                }
                assertEq(p.sumSqrt, expectedRootSum);
                assertEq(p.contributions, expectedContributions);
                totalContributions += expectedContributions;
                totalMatch += p.matchAmount;
                if (r.finalized && !p.claimed) liabilities += p.contributions + p.matchAmount;
            }
            assertEq(r.totalContributions, totalContributions);
            if (!r.finalized) {
                liabilities += r.pool + r.totalContributions;
            } else if (r.refundable) {
                assertEq(totalMatch, 0);
                for (uint256 who; who < 4; ++who) {
                    liabilities += qf.fundingOf(rid, handler.actor(who));
                }
            } else {
                assertEq(totalMatch, r.pool);
            }
        }
        assertEq(token.balanceOf(address(qf)), liabilities);
        assertEq(token.balanceOf(address(qf)), handler.totalIn() - handler.totalOut());
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(qf));
        for (uint256 who; who < 4; ++who) {
            balances += token.balanceOf(handler.actor(who));
        }
        assertEq(balances, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.settleAll();
        assertEq(token.balanceOf(address(qf)), 0, "all round liabilities must be collectable");
        assertEq(handler.totalIn(), handler.totalOut());
    }
}
