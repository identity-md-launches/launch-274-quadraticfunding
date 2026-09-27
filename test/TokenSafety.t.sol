// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";

/// @dev Adversarial dependency used only in tests. Production uses the immutable LaunchToken.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        FalseReturn,
        RevertTransfer,
        NoReturn,
        Tax
    }

    Mode public incoming;
    Mode public outgoing;
    address public blockedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public attempted;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error TransferFailed();

    constructor() ERC20("Adversarial test token", "TEST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configure(Mode incoming_, Mode outgoing_, address blocked_) external {
        incoming = incoming_;
        outgoing = outgoing_;
        blockedRecipient = blocked_;
    }

    function callback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function execute(address target, bytes calldata data) external {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (incoming == Mode.FalseReturn) return false;
        if (incoming == Mode.RevertTransfer) revert TransferFailed();
        _callback();
        super.transferFrom(from, to, amount);
        if (incoming == Mode.Tax) _burn(to, 1);
        if (incoming == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (outgoing == Mode.FalseReturn || to == blockedRecipient) return false;
        if (outgoing == Mode.RevertTransfer) revert TransferFailed();
        _callback();
        super.transfer(to, amount);
        if (outgoing == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _callback() internal {
        if (callbackTarget == address(0)) return;
        attempted = true;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }
}

contract TokenSafetyTest is Test {
    AdversarialToken internal token;
    QuadraticFunding internal qf;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal end;

    function setUp() public {
        vm.warp(1_000_000);
        token = new AdversarialToken();
        qf = new QuadraticFunding(address(token));
        token.mint(address(this), 1e27);
        token.approve(address(qf), type(uint256).max);
        end = block.timestamp + 1 days;
        qf.createRound(block.timestamp, end);
        qf.register(0, ALICE);
    }

    function test_falseReturnAndRevertingDepositsAreAtomic() public {
        token.configure(AdversarialToken.Mode.FalseReturn, AdversarialToken.Mode.Normal, address(0));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        qf.fund(0, 1 ether);
        token.configure(AdversarialToken.Mode.RevertTransfer, AdversarialToken.Mode.Normal, address(0));
        vm.expectRevert(AdversarialToken.TransferFailed.selector);
        qf.contribute(0, 0, 1 ether);
        _assertNoDeposits();
    }

    function test_feeOnTransferDepositsRejectedWithoutAccountingDrift() public {
        token.configure(AdversarialToken.Mode.Tax, AdversarialToken.Mode.Normal, address(0));
        vm.expectRevert(QuadraticFunding.UnexpectedTransferAmount.selector);
        qf.fund(0, 1 ether);
        vm.expectRevert(QuadraticFunding.UnexpectedTransferAmount.selector);
        qf.contribute(0, 0, 1 ether);
        _assertNoDeposits();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_tokensWithoutReturnValueWorkForDepositsClaimsAndReclaims() public {
        token.configure(AdversarialToken.Mode.NoReturn, AdversarialToken.Mode.NoReturn, address(0));
        qf.fund(0, 10 ether);
        qf.contribute(0, 0, 1 ether);
        qf.createRound(block.timestamp, end);
        qf.fund(1, 5 ether);
        vm.warp(end);
        qf.finalize(0);
        qf.finalize(1);
        vm.prank(ALICE);
        qf.claim(0, 0);
        qf.reclaim(1);
        assertEq(token.balanceOf(ALICE), 11 ether);
        assertEq(token.balanceOf(address(qf)), 0);
    }

    function test_failedClaimCanRetryAndDoesNotBlockOtherProjectsOrFinalization() public {
        qf.register(0, BOB);
        qf.fund(0, 2 ether);
        qf.contribute(0, 0, 1 ether);
        qf.contribute(0, 1, 1 ether);
        token.configure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.RevertTransfer, address(0));
        vm.warp(end);
        qf.finalize(0); // Finalization succeeds even when every transfer would fail.
        vm.expectRevert(AdversarialToken.TransferFailed.selector);
        vm.prank(ALICE);
        qf.claim(0, 0);
        assertFalse(qf.project(0, 0).claimed);
        token.configure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        qf.claim(0, 0);
        vm.prank(BOB);
        qf.claim(0, 1);
        assertEq(token.balanceOf(BOB), 2 ether);
        assertEq(token.balanceOf(address(qf)), 2 ether);
        token.configure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, address(0));
        vm.prank(ALICE);
        qf.claim(0, 0);
        assertEq(token.balanceOf(ALICE), 2 ether);
        assertEq(token.balanceOf(address(qf)), 0);
    }

    function test_failedRefundRetainsEntitlementAndDoesNotBlockAnotherFunder() public {
        qf.fund(0, 1 ether);
        token.mint(ALICE, 2 ether);
        vm.startPrank(ALICE);
        token.approve(address(qf), 2 ether);
        qf.fund(0, 2 ether);
        vm.stopPrank();
        vm.warp(end);
        qf.finalize(0);
        token.configure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, address(this));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        qf.reclaim(0);
        assertEq(qf.fundingOf(0, address(this)), 1 ether);
        vm.prank(ALICE);
        qf.reclaim(0);
        token.configure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, address(0));
        qf.reclaim(0);
        assertEq(token.balanceOf(address(qf)), 0);
    }

    function test_reentrancyDuringFundingAndContributionIsBlocked() public {
        token.callback(address(qf), abi.encodeCall(qf.fund, (0, 1)));
        qf.fund(0, 1 ether);
        _assertReentryBlocked();
        token.callback(address(qf), abi.encodeCall(qf.contribute, (0, 0, 1 ether)));
        qf.contribute(0, 0, 1 ether);
        _assertReentryBlocked();
        assertEq(qf.round(0).pool, 1 ether);
        assertEq(qf.round(0).totalContributions, 1 ether);
        assertEq(token.balanceOf(address(qf)), 2 ether);
    }

    function test_crossFunctionReentrancyCannotRegisterProjectsOrCreateRounds() public {
        token.execute(address(qf), abi.encodeCall(qf.createRound, (block.timestamp, end)));
        token.callback(address(qf), abi.encodeCall(qf.register, (1, address(token))));
        qf.fund(1, 1 ether);
        _assertReentryBlocked();
        assertEq(qf.round(1).projectCount, 0);
        token.callback(address(qf), abi.encodeCall(qf.createRound, (block.timestamp, end)));
        qf.fund(1, 1 ether);
        _assertReentryBlocked();
        assertEq(qf.roundCount(), 2);
    }

    function test_payoutCannotReenterClaim() public {
        qf.register(0, address(token));
        qf.fund(0, 10 ether);
        qf.contribute(0, 1, 1 ether);
        vm.warp(end);
        qf.finalize(0);
        token.callback(address(qf), abi.encodeCall(qf.claim, (0, 1)));
        token.execute(address(qf), abi.encodeCall(qf.claim, (0, 1)));
        _assertReentryBlocked();
        assertTrue(qf.project(0, 1).claimed);
        assertEq(token.balanceOf(address(token)), 11 ether);
        assertEq(token.balanceOf(address(qf)), 0);
    }

    function test_funderCannotReenterReclaim() public {
        token.mint(address(token), 10 ether);
        token.execute(address(token), abi.encodeCall(token.approve, (address(qf), 10 ether)));
        token.execute(address(qf), abi.encodeCall(qf.fund, (0, 10 ether)));
        vm.warp(end);
        qf.finalize(0);
        token.callback(address(qf), abi.encodeCall(qf.reclaim, (0)));
        token.execute(address(qf), abi.encodeCall(qf.reclaim, (0)));
        _assertReentryBlocked();
        assertEq(qf.fundingOf(0, address(token)), 0);
        assertEq(token.balanceOf(address(token)), 10 ether);
        assertEq(token.balanceOf(address(qf)), 0);
    }

    function test_unboundedTokenCannotOverflowRoundAccounting() public {
        token.mint(address(this), type(uint256).max - 1e27);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.fund(0, type(uint256).max);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.contribute(0, 0, type(uint256).max);
        qf.fund(0, 1e27);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.contribute(0, 0, 1 ether);
        vm.expectRevert(QuadraticFunding.DepositLimit.selector);
        qf.fund(0, 1);
        vm.warp(end);
        qf.finalize(0);
        qf.reclaim(0);
        assertEq(token.balanceOf(address(this)), type(uint256).max);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(token.attempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertNoDeposits() internal view {
        assertEq(qf.round(0).pool, 0);
        assertEq(qf.round(0).totalContributions, 0);
        assertEq(qf.project(0, 0).sumSqrt, 0);
        assertEq(qf.project(0, 0).contributions, 0);
        assertEq(qf.contributionOf(0, 0, address(this)), 0);
        assertEq(qf.fundingOf(0, address(this)), 0);
        assertEq(token.balanceOf(address(qf)), 0);
    }
}
