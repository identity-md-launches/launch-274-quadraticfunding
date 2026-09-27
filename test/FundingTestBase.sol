// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract FundingTestBase is Test {
    LaunchToken internal mtch;
    QuadraticFunding internal qf;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant PAYOUT = address(0x1234);
    uint256 internal start;
    uint256 internal end;

    function setUp() public virtual {
        vm.warp(1_000_000);
        mtch = new LaunchToken();
        qf = new QuadraticFunding(address(mtch));
        mtch.approve(address(qf), type(uint256).max);
        _seed(ALICE);
        _seed(BOB);
        _seed(CAROL);
        start = block.timestamp + 1 days;
        end = start + 7 days;
        qf.createRound(start, end);
    }

    function _seed(address account) internal {
        mtch.transfer(account, 10_000_000 ether);
        vm.prank(account);
        mtch.approve(address(qf), type(uint256).max);
    }

    function _contribute(address account, uint256 pid, uint256 amount) internal {
        vm.prank(account);
        qf.contribute(0, pid, amount);
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(account);
        qf.fund(0, amount);
    }

    function _finish() internal {
        vm.warp(end);
        vm.prank(CAROL);
        qf.finalize(0);
    }
}
