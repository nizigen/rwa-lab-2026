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

/// @title Ex6: handler for randomized queue operations
/// @notice Uses funded, approved users to exercise enqueue, settle, and claim.
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev Counters verify that queue operations ran successfully.
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev Keep NAV between $0.50 and $2 so runs exercise queue accounting.
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev Simulate sale proceeds arriving as cash in the vault.
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    function enqueue(uint256 userSeed, uint256 shares) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), shares);
        queue.enqueue(shares);
        vm.stopPrank();
        ++ghost_enqueues;
    }

    /// @dev A budget below the head ticket payout is valid and settles no tickets.
    function settle(uint256 assets) external {
        uint256 reserves = vault.reserveBalance();
        if (reserves == 0) return;
        assets = bound(assets, 1, reserves);
        uint256 filled = queue.settle(assets);
        if (filled > 0) ++ghost_settles;
    }

    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        if (queue.claimable(user) == 0) return;

        vm.prank(user);
        queue.claim();
        ++ghost_claims;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);
        usdc.faucet(address(handler), 300_000e6);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // Let the fuzzer call only the handler's own actions, not its inherited helpers
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Escrow must cover exactly the shares in unsettled tickets.
    function invariant_EscrowConservation() public view {
        assertEq(tBill.balanceOf(address(queue)), queue.pendingShares(), "escrow conservation");
    }

    /// @dev Every settled claim must have cash in the queue. Pending requests may await T-Bill sales.
    function invariant_SettlementSolvency() public view {
        assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable(), "settlement solvency");
    }

    function test_HandlerExercisesEveryQueueAction() public {
        handler.subscribe(0, 1_000e6);
        handler.attest(1.25e8);
        handler.enqueue(0, 1_000e18);
        handler.fundVault(250e6);
        handler.settle(1_250e6);
        handler.claim(0);

        assertEq(handler.ghost_enqueues(), 1);
        assertEq(handler.ghost_settles(), 1);
        assertEq(handler.ghost_claims(), 1);
        assertEq(queue.pendingShares(), 0);
        assertEq(queue.pendingAssets(), 0);
        assertEq(queue.totalClaimable(), 0);
        assertEq(tBill.balanceOf(address(queue)), 0);
        assertEq(usdc.balanceOf(address(queue)), 0);
    }
}
