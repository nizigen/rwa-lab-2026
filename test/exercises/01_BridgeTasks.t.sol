// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";

/// @title Ex2-Ex4: custody, attestation, and admission tests
contract BridgeTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant NAV_1_25 = 1.25e8;

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));

        compliance.setWhitelisted(admin, true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(bob, true);
    }

    function _subscribe(address user, uint256 assets) internal {
        usdc.faucet(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.subscribe(assets);
        vm.stopPrank();
    }

    /// @dev Subscription cash stays in the vault; issuing shares does not buy T-Bills.
    function test_Ex2_SharesExistWhileTheCustodianHoldsNothing() public {
        _subscribe(alice, 1_000e6);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(custodian.realHoldings(), 0);
        assertEq(vault.reserveBalance(), 1_000e6);
    }

    /// @dev A purchase report changes reported holdings without moving cash.
    function test_Ex2_RealHoldingsIsJustANumber() public {
        assertEq(custodian.realHoldings(), 0);
        custodian.recordPurchase(1_000_000e6);
        assertEq(custodian.realHoldings(), 1_000_000e6);
        assertEq(usdc.balanceOf(address(custodian)), 0);
    }

    /// @dev Updating NAV changes claim value without changing the share balance.
    function test_Ex3_TheClaimFloats_TheShareCountDoesNot() public {
        _subscribe(alice, 1_000e6);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(vault.totalClaimValue(), 1_000e6);

        vault.attest(int256(NAV_1_25));
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 1_250e6);
        assertEq(vault.totalClaimValue(), 1_250e6);
    }

    /// @dev All holders use the same NAV report.
    function test_Ex3_OneCallMovesTheWholeBook() public {
        _subscribe(alice, 1_000e6);
        _subscribe(bob, 500e6);
        assertEq(vault.totalClaimValue(), 1_500e6);

        vault.attest(int256(50e8));
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(tBill.balanceOf(bob), 500e18);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 50_000e6);
        assertEq(vault.assetsForShares(tBill.balanceOf(bob)), 25_000e6);
        assertEq(vault.totalClaimValue(), 75_000e6);
    }

    /// @dev Fund and approve first so the revert tests admission, not insufficient cash.
    function test_Ex4_NoKyc_NoShares_EvenIfYouPay() public {
        usdc.faucet(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vault.subscribe(1_000e6);
        vm.stopPrank();
        assertEq(tBill.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(attacker), 1_000e6);
        assertEq(vault.reserveBalance(), 0);
    }

    /// @dev An approved sender cannot transfer shares to an unapproved receiver.
    function test_Ex4_TransferChecksBothEndpoints() public {
        _subscribe(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        tBill.transfer(attacker, 1e18);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(tBill.balanceOf(attacker), 0);
    }

    /// @dev Removing a holder from the whitelist also blocks burning their shares.
    function test_Ex4_FreezeBeatsConfiscation() public {
        _subscribe(alice, 1_000e6);
        compliance.setWhitelisted(alice, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.transfer(bob, 1e18);

        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.burn(alice, 1_000e18);
        assertEq(tBill.balanceOf(alice), 1_000e18);
    }
}
