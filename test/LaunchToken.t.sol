// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FactoryHarness {
    function deploy() external returns (LaunchToken token, QuadraticFunding app) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        app = new QuadraticFunding{salt: bytes32(uint256(2))}(address(token));
    }
}

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndEntireFixedSupply() public view {
        assertEq(token.name(), "Match");
        assertEq(token.symbol(), "MTCH");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferMovesExactAmount(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_approvalTransferFromAndInsufficientAllowance() public {
        token.approve(ALICE, 5 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 3 ether));
        assertEq(token.balanceOf(BOB), 3 ether);
        assertEq(token.allowance(address(this), ALICE), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 2 ether, 3 ether)
        );
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 3 ether);
    }

    function test_zeroRecipientAndInsufficientBalanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_adminAndMintSelectorsCannotChangeSupply() public {
        string[9] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory payload = abi.encodeWithSignature(signatures[i], ALICE, 1e27);
            (bool deployerSuccess,) = address(token).call(payload);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool attackerSuccess,) = address(token).call(payload);
            assertFalse(attackerSuccess);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_factoryConstructionNeedsNoBalancesOrInitialization() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken deployedToken, QuadraticFunding app) = factory.deploy();
        assertEq(deployedToken.balanceOf(address(factory)), 1e27);
        assertEq(deployedToken.totalSupply(), 1e27);
        assertEq(deployedToken.balanceOf(address(app)), 0);
        assertEq(address(app.token()), address(deployedToken));
        assertEq(app.roundCount(), 0);
        vm.prank(ALICE);
        app.createRound(block.timestamp, block.timestamp + 1 days);
        assertEq(app.round(0).creator, ALICE);
        _checkRuntime(address(deployedToken));
        _checkRuntime(address(app));
    }

    function test_constructorRejectsZeroAndNonContractToken() public {
        vm.expectRevert(QuadraticFunding.InvalidToken.selector);
        new QuadraticFunding(address(0));
        vm.expectRevert(QuadraticFunding.InvalidToken.selector);
        new QuadraticFunding(ALICE);
    }

    function _checkRuntime(address target) internal view {
        bytes memory runtime = target.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden executable opcode");
            }
        }
    }
}
