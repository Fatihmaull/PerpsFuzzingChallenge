// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MinimumPerps} from "../../src/MinimumPerps.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockAggregatorV3} from "../Mock/MockAggregatorV3.sol";
import {IAggregatorV3} from "../../src/Interfaces/IAggregatorV3.sol";
import {IOracle, Oracle} from "../../src/Oracle.sol";
import {Errors} from "../../src/Errors.sol";

/// @notice Minimal, deterministic reproductions of the bugs found by the invariant suite.
///         Each test PASSES when the bug is present. See Handler.sol for the write-up.
contract BugPoCs is Test {
    MinimumPerps public perps;
    MockERC20 public usdc;
    MockERC20 public btc;
    MockAggregatorV3 public btcFeed;
    MockAggregatorV3 public usdcFeed;

    address public lp = makeAddr("lp");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        btc = new MockERC20("BTC", "BTC", 8);
        btcFeed = new MockAggregatorV3(8, "BTC", 1, 0, int256(50_000e8), 0, 0, 0);
        usdcFeed = new MockAggregatorV3(8, "USDC", 1, 0, int256(1e8), 0, 0, 0);

        Oracle oracle = new Oracle();
        oracle.updatePricefeedConfig(address(usdc), IAggregatorV3(usdcFeed), 3600, 1e16);
        oracle.updatePricefeedConfig(address(btc), IAggregatorV3(btcFeed), 3600, 1e14);

        perps = new MinimumPerps("MinPerps", "MP", address(btc), IERC20(usdc), IOracle(oracle), 0);
    }

    // BUG 1: OI can exceed 50% of liquidity, because longs are reserved at their current value
    function test_bug1_openInterestExceedsHalfOfLiquidityAfterPriceDrop() public {
        _deposit(lp, 1_000e6);
        _increase(alice, true, 500e30, 100e6); // OI = $500 = exactly 50% of $1,000

        _setBtcPrice(25_000e8); // longs are now "reserved" at $250 only

        _increase(bob, true, 250e30, 100e6); // accepted

        uint256 netOI = perps.openInterestLong() + perps.openInterestShort();
        uint256 limit = perps.totalDeposits() * perps.getCollateralPrice() / 2;
        assertEq(netOI, 750e30);
        assertEq(limit, 500e30);
        assertGt(netOI, limit, "invariant 1 broken");
    }

    // BUG 2: increasePosition never checks max leverage; the new position is instantly liquidatable
    function test_bug2_increaseDoesNotEnforceMaxLeverage() public {
        _deposit(lp, 1_000e6);
        _increase(alice, true, 100e30, 1e6); // 100x leverage, max is 20x

        assertTrue(perps.isPositionLiquidatable(alice, true));

        vm.prank(keeper);
        perps.liquidate(alice, true); // keeper liquidates it in the same block
    }

    // BUG 3: underflow in insolvent liquidations means bad debt can never be liquidated
    function test_bug3_insolventPositionCannotBeLiquidated() public {
        _deposit(lp, 10_000e6);
        _increase(alice, true, 1_000e30, 50e6); // 20x

        _setBtcPrice(45_000e8); // -10% => $100 loss on $50 collateral

        assertTrue(perps.isPositionLiquidatable(alice, true));

        vm.prank(keeper);
        vm.expectRevert(stdError.arithmeticError);
        perps.liquidate(alice, true);

        // The owner cannot close it either; the position (and its OI) is stuck forever
        vm.prank(alice);
        vm.expectRevert();
        perps.decreasePosition(true, 1_000e30, 0);
    }

    // BUG 4: isPositionLiquidatable compares a USD value with a token amount, so borrowing fees are ignored
    function test_bug4_borrowingFeesIgnoredByLiquidationCheck() public {
        perps.setBorrowingPerSharePerSecond(perps.MAX_BORROWING_RATE()); // 10% / year
        _deposit(lp, 10_000e6);
        _increase(alice, true, 500e30, 50e6); // 10x

        _warp(730 days);

        uint256 fees = perps.getPendingBorrowingFees(alice, true);
        assertApproxEqRel(fees, 100e6, 0.01e18); // ~$100 owed on $50 of collateral
        assertFalse(perps.isPositionLiquidatable(alice, true), "should be liquidatable");

        vm.prank(keeper);
        vm.expectRevert(Errors.PositionNotLiquidatable.selector);
        perps.liquidate(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientCollateralForBorrowingFees.selector, fees, 50e6));
        perps.decreasePosition(true, 500e30, 0);
    }

    // BUG 5: totalCollateral is only ever incremented
    function test_bug5_totalCollateralNeverDecreases() public {
        _deposit(lp, 1_000e6);
        _increase(alice, true, 100e30, 50e6);

        vm.prank(alice);
        perps.decreasePosition(true, 100e30, 0); // fully closed, all collateral returned

        assertEq(usdc.balanceOf(alice), 50e6);
        assertEq(perps.totalCollateral(), 50e6, "still reports the closed position's collateral");
    }

    // BUG 6: rounding up the closed tokens of a long can delete a position while OI stays behind
    function test_bug6_partialCloseLeavesOrphanedOpenInterest() public {
        _deposit(lp, 1_000e6);
        _increase(alice, true, 100e30, 50e6); // 2e5 tokens, $0.0005 per token unit

        uint256 remaining = 4e26; // less than one token unit's worth
        vm.prank(alice);
        perps.decreasePosition(true, 100e30 - remaining, 0);

        (uint256 sizeInUsd,,,) = perps.longPositions(alice);
        assertEq(sizeInUsd, 0, "position deleted");
        assertEq(perps.openInterestLong(), remaining, "orphaned OI nobody can ever close");
    }

    // BUG 7: realizing profit drains totalDeposits without any utilization check
    function test_bug7_profitRealizationPushesOpenInterestOverLimit() public {
        _deposit(lp, 1_000e6);
        _increase(alice, true, 250e30, 50e6);
        _increase(bob, true, 250e30, 50e6); // OI = $500 = exactly 50% of $1,000

        _setBtcPrice(200_000e8); // 4x

        vm.prank(alice);
        perps.decreasePosition(true, 250e30, 0); // realizes $750 profit paid by LPs

        uint256 netOI = perps.openInterestLong() + perps.openInterestShort();
        uint256 limit = perps.totalDeposits() * perps.getCollateralPrice() / 2;
        assertEq(netOI, 250e30);
        assertEq(limit, 125e30);
        assertGt(netOI, limit, "invariant 1 broken");
    }

    // ---------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(perps), amount);
        perps.deposit(amount, who);
        vm.stopPrank();
    }

    function _increase(address who, bool isLong, uint256 sizeUsd, uint256 collateral) internal {
        usdc.mint(who, collateral);
        vm.startPrank(who);
        usdc.approve(address(perps), collateral);
        perps.increasePosition(isLong, sizeUsd, collateral);
        vm.stopPrank();
    }

    function _setBtcPrice(uint256 price) internal {
        btcFeed.setPrice(int256(price));
        usdcFeed.setPrice(usdcFeed.answer());
    }

    function _warp(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        btcFeed.setPrice(btcFeed.answer());
        usdcFeed.setPrice(usdcFeed.answer());
    }
}
