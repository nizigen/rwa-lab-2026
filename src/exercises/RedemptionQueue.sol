// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TBillToken} from "../TBillToken.sol";
import {TBillVault} from "../TBillVault.sol";

/// @title Ex5: FIFO redemption queue
/// @notice Shares are escrowed at enqueue NAV. Settlement funds whole tickets in order.
contract RedemptionQueue is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    TBillVault public immutable vault;
    TBillToken public immutable tBill;
    IERC20 public immutable usdc;

    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    uint256 public constant NAV_PRECISION = 1e8;
    uint256 public constant SHARE_PRECISION = 1e18;
    uint256 public constant ASSET_PRECISION = 1e6;
    /// @dev Divide by 10^(18 + 8 - 6) to express the payout in USDC units.
    uint256 public constant DECIMALS_SCALE = 1e20;

    struct Request {
        address owner;
        uint256 shares; // escrowed shares, 18 decimals
        uint256 assetsLocked; // payout promised at the NAV when enqueued, 6 decimals
        bool settled;
    }

    Request[] public requests;

    /// @dev Index of the first unsettled request.
    uint256 public head;
    /// @dev Shares held by this contract, backing the unsettled requests
    uint256 public pendingShares;
    /// @dev Assets still owed to the unsettled requests, 6 decimals
    uint256 public pendingAssets;
    /// @dev Cash settled and waiting to be claimed
    uint256 public totalClaimable;
    mapping(address => uint256) public claimable;

    event RedeemRequested(
        uint256 indexed id, address indexed owner, uint256 shares, uint256 assetsLocked
    );
    event Settled(uint256 indexed id, address indexed owner, uint256 assets);
    event Claimed(address indexed owner, uint256 assets);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToClaim();

    constructor(TBillVault vault_, TBillToken tBill_, IERC20 usdc_, address admin) {
        if (
            address(vault_) == address(0) || address(tBill_) == address(0)
                || address(usdc_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        tBill = tBill_;
        usdc = usdc_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLER_ROLE, admin);
    }

    function queueLength() external view returns (uint256) {
        return requests.length;
    }

    function requestAt(uint256 id) external view returns (Request memory) {
        return requests[id];
    }

    /// @notice Convert 18-decimal shares and 8-decimal NAV to 6-decimal USDC.
    function assetsAtNav(uint256 shares, uint256 nav) public pure returns (uint256) {
        return shares * nav / DECIMALS_SCALE;
    }

    /// @notice Escrow shares and lock the payout at the current NAV.
    /// @dev Later NAV updates do not change this ticket.
    function enqueue(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares == 0) revert ZeroAmount();
        IERC20(address(tBill)).safeTransferFrom(msg.sender, address(this), shares);
        uint256 assetsLocked = assetsAtNav(shares, vault.navPerShare());
        id = requests.length;
        requests.push(Request(msg.sender, shares, assetsLocked, false));
        pendingShares += shares;
        pendingAssets += assetsLocked;
        emit RedeemRequested(id, msg.sender, shares, assetsLocked);
    }

    /// @notice Fund complete tickets in FIFO order, up to the cash budget.
    /// @dev Stop if the head ticket cannot be funded; later requests cannot skip it.
    function settle(uint256 assets)
        external
        onlyRole(SETTLER_ROLE)
        nonReentrant
        returns (uint256 filled)
    {
        while (head < requests.length) {
            Request storage request = requests[head];
            uint256 payout = request.assetsLocked;
            if (payout > assets - filled) break;

            uint256 id = head;
            request.settled = true;
            head = id + 1;
            pendingShares -= request.shares;
            pendingAssets -= payout;
            claimable[request.owner] += payout;
            totalClaimable += payout;
            filled += payout;

            vault.releaseReserves(address(this), payout);
            tBill.burn(address(this), request.shares);
            emit Settled(id, request.owner, payout);
        }
    }

    /// @notice Withdraw cash from settled tickets.
    /// @dev Clear the balance before transferring cash to prevent repeated claims.
    function claim() external nonReentrant returns (uint256 assets) {
        assets = claimable[msg.sender];
        if (assets == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= assets;
        usdc.safeTransfer(msg.sender, assets);
        emit Claimed(msg.sender, assets);
    }
}
