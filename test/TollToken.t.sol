// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TollToken} from "../src/TollToken.sol";
import {Opcodes} from "./helpers/Opcodes.sol";

contract TollTokenTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    TollToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new TollToken();
    }

    function test_zeroArgumentConstructorMintsExactlyOneE27ToDeployer() public {
        bytes memory creationCode = type(TollToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        TollToken fresh = TollToken(deployed);
        assertEq(fresh.totalSupply(), SUPPLY, "supply is 1e27, not 1e24");
        assertEq(fresh.totalSupply(), 1_000_000_000 ether);
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
        assertEq(fresh.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_metadata() public view {
        assertEq(token.name(), "TOLLGATE");
        assertEq(token.symbol(), "TOLL");
        assertEq(uint256(token.decimals()), 18);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRejectsInsufficientBalanceAndZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(TollToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
        vm.expectRevert(TollToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        assertTrue(token.approve(alice, 3 ether));
        assertEq(token.allowance(address(this), alice), 3 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 2 ether));
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(address(this), alice), 1 ether);
        vm.prank(alice);
        vm.expectRevert(TollToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 2 ether);
    }

    function test_infiniteAllowanceIsNotDecreased() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_burnLowersSupply() public {
        token.burn(10 ether);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        vm.prank(alice);
        vm.expectRevert(TollToken.InsufficientBalance.selector);
        token.burn(1);
    }

    function test_burnFromUsesAllowance() public {
        token.approve(alice, 4 ether);
        vm.prank(alice);
        token.burnFrom(address(this), 4 ether);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
        assertEq(token.allowance(address(this), alice), 0);
        vm.prank(alice);
        vm.expectRevert(TollToken.InsufficientAllowance.selector);
        token.burnFrom(address(this), 1);
    }

    /// @dev The shapes the admission floor probes: none may exist, none may raise supply.
    function test_noAdminOrMintSelectorExists() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "pause()",
            "setMinter(address)",
            "owner()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    function test_runtimeHasNoEscapeHatch() public view {
        Opcodes.assertNoEscapeHatch(address(token).code);
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
