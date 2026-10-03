// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MinimumPerps} from "../../src/MinimumPerps.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockAggregatorV3} from "../Mock/MockAggregatorV3.sol";
import {IAggregatorV3} from "../../src/Interfaces/IAggregatorV3.sol";
import {IOracle, Oracle} from "../../src/Oracle.sol";
import {Handler} from "./Handler.sol";

/// @notice Invariant suite for MinimumPerps. See the bug report at the top of Handler.sol.
contract MinimumPerpsInvariants is Test {
    MinimumPerps public perps;
    MockERC20 public usdc;
    MockERC20 public btc;
    MockAggregatorV3 public btcFeed;
    MockAggregatorV3 public usdcFeed;
    Handler public handler;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        btc = new MockERC20("BTC", "BTC", 8);

        btcFeed = new MockAggregatorV3(8, "BTC", 1, 0, int256(50_000e8), 0, 0, 0);
        usdcFeed = new MockAggregatorV3(8, "USDC", 1, 0, int256(1e8), 0, 0, 0);
        btcFeed.setPrice(int256(50_000e8));
        usdcFeed.setPrice(int256(1e8));

        Oracle oracle = new Oracle();
        oracle.updatePricefeedConfig(address(usdc), IAggregatorV3(usdcFeed), 3600, 1e16);
        oracle.updatePricefeedConfig(address(btc), IAggregatorV3(btcFeed), 3600, 1e14);

        perps = new MinimumPerps("MinPerps", "MP", address(btc), IERC20(usdc), IOracle(oracle), 0);

        handler = new Handler(perps, usdc, btcFeed, usdcFeed, address(this));

        // Seed the market with liquidity so trading actions are reachable from the first call
        handler.deposit(0, 1_000_000e6);

        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // Required invariants
    // ---------------------------------------------------------------------

    /// @notice 1. netOI <= depositedLiquidity * collateralPrice / 2
    /// @dev netOI is taken as the aggregate notional (long + short OI in USD, 30 decimals) and
    ///      depositedLiquidity as `totalDeposits` (LP-owned collateral tokens).
    function invariant_openInterestAtMostHalfOfLiquidity() public view {
        uint256 netOI = perps.openInterestLong() + perps.openInterestShort();
        uint256 limit = perps.totalDeposits() * perps.getCollateralPrice() / 2;
        assertLe(netOI, limit, string.concat("OI > 50% of liquidity, first breached by: ", handler.ghost_oiBreachAction()));
    }

    /// @notice 2. collateralWithdrawn <= collateralDeposited (profit excluded), per trader
    function invariant_traderCannotWithdrawMoreCollateralThanDeposited() public view {
        for (uint256 i; i < handler.tradersLength(); i++) {
            address trader = handler.traders(i);
            assertLe(
                handler.ghost_collateralWithdrawn(trader),
                handler.ghost_collateralDeposited(trader),
                "trader withdrew more collateral than deposited"
            );
        }
    }

    // ---------------------------------------------------------------------
    // Additional invariants
    // ---------------------------------------------------------------------

    /// @notice 3. `totalCollateral` must equal the sum of collateral held by open positions
    function invariant_totalCollateralMatchesPositions() public view {
        assertEq(perps.totalCollateral(), handler.sumPositionCollateral(), "totalCollateral out of sync");
    }

    /// @notice 4. Aggregate open interest must equal the sum of open positions
    function invariant_openInterestMatchesPositions() public view {
        (uint256 longUsd, uint256 longTokens) = handler.sumPositionSizes(true);
        (uint256 shortUsd, uint256 shortTokens) = handler.sumPositionSizes(false);
        assertEq(perps.openInterestLong(), longUsd, "openInterestLong out of sync");
        assertEq(perps.openInterestTokensLong(), longTokens, "openInterestTokensLong out of sync");
        assertEq(perps.openInterestShort(), shortUsd, "openInterestShort out of sync");
        assertEq(perps.openInterestTokensShort(), shortTokens, "openInterestTokensShort out of sync");
    }

    /// @notice 5. A freshly opened / increased position must respect max leverage (20x)
    function invariant_noPositionOpenedAboveMaxLeverage() public view {
        assertFalse(handler.ghost_openedAboveMaxLeverage(), "position opened above max leverage");
        assertFalse(handler.ghost_openedLiquidatable(), "position liquidatable right after being opened");
    }

    /// @notice 6. The market must hold enough tokens to cover LP deposits plus trader collateral
    function invariant_marketIsSolvent() public view {
        assertGe(
            usdc.balanceOf(address(perps)),
            perps.totalDeposits() + handler.sumPositionCollateral(),
            "market balance < deposits + collateral"
        );
    }

    /// @notice 7. Traders are always paid the full realized profit they are owed
    function invariant_profitIsPaidInFull() public view {
        assertFalse(handler.ghost_profitUnderpaid(), "trader received less than realized profit");
    }

    /// @notice 8. The vault's share pricing (totalAssets) must never revert
    function invariant_totalAssetsDoesNotRevert() public view {
        try perps.totalAssets() returns (uint256) {}
        catch {
            assertTrue(false, "totalAssets() reverts: LP deposits/withdrawals are bricked");
        }
    }

    /// @notice 9. Liveness: every open position can always be exited, either closed by its owner
    ///         (when healthy) or liquidated by anyone (when unhealthy). Checked on a state snapshot.
    function invariant_everyPositionCanBeExited() public {
        for (uint256 i; i < handler.tradersLength(); i++) {
            address trader = handler.traders(i);
            _assertCanExit(trader, true);
            _assertCanExit(trader, false);
        }
    }

    /// @notice 10. A position whose pending borrowing fees exceed its collateral must be liquidatable
    function invariant_feeInsolventPositionsAreLiquidatable() public view {
        for (uint256 i; i < handler.tradersLength(); i++) {
            address trader = handler.traders(i);
            for (uint256 j; j < 2; j++) {
                bool isLong = j == 0;
                (uint256 sizeInUsd,, uint256 collateralAmount,) =
                    isLong ? perps.longPositions(trader) : perps.shortPositions(trader);
                if (sizeInUsd == 0) continue;
                if (perps.getPendingBorrowingFees(trader, isLong) >= collateralAmount) {
                    assertTrue(perps.isPositionLiquidatable(trader, isLong), "fees >= collateral but not liquidatable");
                }
            }
        }
    }

    function _assertCanExit(address trader, bool isLong) internal {
        (uint256 sizeInUsd,,,) = isLong ? perps.longPositions(trader) : perps.shortPositions(trader);
        if (sizeInUsd == 0) return;

        uint256 snapshot = vm.snapshotState();
        bool exited;
        if (perps.isPositionLiquidatable(trader, isLong)) {
            vm.prank(address(0xBEEF));
            try perps.liquidate(trader, isLong) { exited = true; } catch {}
        } else {
            vm.prank(trader);
            try perps.decreasePosition(isLong, sizeInUsd, 0) { exited = true; } catch {}
        }
        vm.revertToState(snapshot);

        assertTrue(exited, "position can be neither closed nor liquidated");
    }

    function afterInvariant() external view {
        console.log("deposit          ", handler.calls("deposit"));
        console.log("withdraw         ", handler.calls("withdraw"));
        console.log("increasePosition ", handler.calls("increasePosition"));
        console.log("decreasePosition ", handler.calls("decreasePosition"));
        console.log("liquidate        ", handler.calls("liquidate"));
        console.log("setBtcPrice      ", handler.calls("setBtcPrice"));
        console.log("warp             ", handler.calls("warp"));
        console.log("setBorrowingRate ", handler.calls("setBorrowingRate"));
    }
}
