// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

/*
 * ==========================================================================================
 *  MinimumPerps invariant suite - BUG REPORT        (submission keyword: "clear screen")
 * ==========================================================================================
 *
 *  Run:   forge test --mc MinimumPerpsInvariants      (invariant campaign)
 *         forge test --mc BugPoCs -vv                  (deterministic reproductions)
 *
 *  Invariant results (256 runs x 100 depth; the passing ones were re-run at 1000 x 200):
 *
 *   #  Invariant                                                      Result
 *   1  netOI <= totalDeposits * collateralPrice / 2                   BROKEN  (Bug 1, Bug 7)
 *   2  collateralWithdrawn <= collateralDeposited (per trader)        holds
 *   3  totalCollateral == sum of position collateral                  BROKEN  (Bug 5)
 *   4  openInterest{Long,Short}{,Tokens} == sum of positions          BROKEN  (Bug 6)
 *   5  a just-opened position respects max leverage / is healthy      BROKEN  (Bug 2)
 *   6  USDC balance >= totalDeposits + sum of position collateral     holds
 *   7  traders are always paid their full realized profit            holds
 *   8  totalAssets() never reverts                                    holds
 *   9  every position can be exited (closed or liquidated)            BROKEN  (Bug 3)
 *  10  fees >= collateral  =>  position is liquidatable               BROKEN  (Bug 4)
 *
 *  Note on #1: "netOI" is interpreted as the aggregate notional, openInterestLong +
 *  openInterestShort (USD, 30 decimals), and "depositedLiquidity" as totalDeposits.
 *
 * ------------------------------------------------------------------------------------------
 *  BUG 1 (High) - Max-utilization check lets OI exceed 50% of liquidity after a price drop
 *  Invariant 1. PoC: test_bug1_openInterestExceedsHalfOfLiquidityAfterPriceDrop
 *    _validateMaxUtilization() reserves longs at their *current* value
 *    (openInterestTokensLong * indexPrice) instead of their notional (openInterestLong).
 *    When the index price falls, the long "reserve" shrinks and new positions (or LP
 *    withdrawals, which run the same check) are accepted even though notional OI is
 *    already at the cap; the fuzzer finds both paths. Example: $1,000 deposits, $500 long at
 *    $50k (at the cap); price -> $25k; a further $250 long is accepted => OI $750 > $500.
 *    Fix: reserve max(openInterestLong, openInterestTokensLong * price) for longs, or
 *    validate against notional OI as the spec states.
 *
 *  BUG 2 (High) - increasePosition never enforces maxLeverage
 *  Invariant 5. PoC: test_bug2_increaseDoesNotEnforceMaxLeverage
 *    maxLeverage is only consulted inside isPositionLiquidatable(), which increasePosition
 *    never calls. A 100x position (1 USDC for $100) is accepted and is liquidatable in the
 *    same block, so a keeper (or the trader from a second account) can farm the 2% fee and
 *    traders can take arbitrarily leveraged, instantly-insolvent positions.
 *    Fix: at the end of increasePosition, revert if isPositionLiquidatable(msg.sender, isLong).
 *
 *  BUG 3 (Critical) - Insolvent liquidations always revert (underflow): bad debt is stuck
 *  Invariant 9. PoC: test_bug3_insolventPositionCannotBeLiquidated
 *    In _decreasePosition(), when loss > collateral during a liquidation:
 *        positionLossInCollateral = position.collateralAmount;
 *        position.collateralAmount = 0;
 *        ...
 *        position.collateralAmount -= positionLossInCollateral;   // 0 - x  => panic 0x11
 *    So exactly the positions that most need liquidating (underwater ones) can never be
 *    liquidated, and the owner can't close them either (InsufficientCollateralForLoss).
 *    Their OI stays forever, blocking LP withdrawals / new positions, and if the price
 *    recovers the trader can close for a profit, i.e. a free option paid for by LPs.
 *    Fix: only cap positionLossInCollateral (do not zero collateralAmount before the
 *    subtraction).
 *
 *  BUG 4 (High) - Borrowing fees are effectively ignored by isPositionLiquidatable
 *  Invariant 10. PoC: test_bug4_borrowingFeesIgnoredByLiquidationCheck
 *    collateralValue is a USD amount (30 decimals) but _calculateBorrowingFees() returns
 *    collateral *tokens* (6 decimals); the two are compared/subtracted directly, so fees
 *    are off by a factor of collateralPrice (1e24). A 10x long that owes ~$100 of fees on
 *    $50 collateral is reported healthy: liquidate() reverts PositionNotLiquidatable and
 *    decreasePosition() reverts InsufficientCollateralForBorrowingFees => stuck position,
 *    unpaid fees for LPs.
 *    Fix: compare against borrowingFees * getCollateralPrice().
 *
 *  BUG 5 (Medium) - totalCollateral is never decreased
 *  Invariant 3. PoC: test_bug5_totalCollateralNeverDecreases
 *    increasePosition adds to totalCollateral, but nothing subtracts collateral withdrawn,
 *    fees/losses moved to LPs, or liquidation fees. The value only grows, so anything
 *    (UI, integrations, future accounting) that relies on it is wrong.
 *    Fix: decrement it in _decreasePosition / increasePosition wherever collateral leaves.
 *
 *  BUG 6 (Low) - Partial long close can delete a position and orphan its OI
 *  Invariant 4. PoC: test_bug6_partialCloseLeavesOrphanedOpenInterest
 *    For longs, sizeDeltaTokens is rounded *up*. If the remaining size is worth less than
 *    one token unit, all tokens are removed, sizeInTokens == 0 triggers `delete`, but only
 *    sizeDeltaUsd was taken off openInterestLong. The leftover notional stays in OI forever
 *    (counted against utilization, impossible to close) and its PnL is never settled.
 *    Fix: when sizeInTokens becomes 0, also remove the remaining sizeInUsd from OI (or
 *    treat the decrease as a full close).
 *
 *  BUG 7 (Medium) - Realized profit drains liquidity with no utilization check
 *  Invariant 1. PoC: test_bug7_profitRealizationPushesOpenInterestOverLimit
 *    decreasePosition / liquidate pay profit out of totalDeposits without re-checking
 *    utilization, and nothing caps long profit (no ADL / max PnL factor). After a 4x price
 *    move, closing one winner leaves the remaining OI at 2x the 50% cap and LPs locked in.
 *    Fix: cap per-position/aggregate profit relative to the pool, or auto-deleverage
 *    winners when the pool falls below the reserve requirement.
 *
 * ------------------------------------------------------------------------------------------
 *  Other observations (not invariant-checked)
 *   - The liquidation fee is taken before LP losses are settled, so on insolvent
 *     liquidations the keeper is paid from what should go to LPs (documented as a choice).
 *   - LPs redeem at totalAssets(), which includes *unrealized* trader PnL; withdrawing
 *     against unrealized trader losses is paid out of trader collateral.
 *   - totalAssets() reverts (TraderPnlExceedsDeposits) if trader PnL ever exceeds deposits,
 *     bricking LP deposits/withdrawals; not reached with +/-20% price steps.
 *   - getPosition() is missing `view`; MinimumPerps/Oracle import forge-std/Test.sol in
 *     production code; the oracle ignores feed decimals and answeredInRound.
 * ==========================================================================================
 */

import "forge-std/Test.sol";
import {MinimumPerps} from "../../src/MinimumPerps.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockAggregatorV3} from "../Mock/MockAggregatorV3.sol";

contract Handler is Test {
    MinimumPerps public perps;
    MockERC20 public usdc;
    MockAggregatorV3 public btcFeed;
    MockAggregatorV3 public usdcFeed;
    address public owner;

    address[] public lps;
    address[] public traders;
    address public liquidator = makeAddr("liquidator");

    // ---------------------------------------------------------------------
    // Ghost variables
    // ---------------------------------------------------------------------

    // Invariant 2: collateral a trader put in vs. collateral they got back (profit excluded)
    mapping(address => uint256) public ghost_collateralDeposited;
    mapping(address => uint256) public ghost_collateralWithdrawn;
    mapping(address => uint256) public ghost_profitReceived;

    // A trader received less than the profit the market owed them
    bool public ghost_profitUnderpaid;

    // A position was liquidatable / above max leverage right after increasePosition
    bool public ghost_openedLiquidatable;
    bool public ghost_openedAboveMaxLeverage;

    // Invariant 1 tracking: which action first pushed OI above 50% of liquidity
    string public ghost_oiBreachAction;

    // Call counters, printed by the invariant test for coverage sanity
    mapping(bytes32 => uint256) public calls;

    // Price bounds for the index token (feed has 8 decimals)
    uint256 internal constant MIN_BTC_PRICE = 1_000e8;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e8;

    constructor(
        MinimumPerps _perps,
        MockERC20 _usdc,
        MockAggregatorV3 _btcFeed,
        MockAggregatorV3 _usdcFeed,
        address _owner
    ) {
        perps = _perps;
        usdc = _usdc;
        btcFeed = _btcFeed;
        usdcFeed = _usdcFeed;
        owner = _owner;

        lps.push(makeAddr("lp0"));
        lps.push(makeAddr("lp1"));
        traders.push(makeAddr("trader0"));
        traders.push(makeAddr("trader1"));
        traders.push(makeAddr("trader2"));
    }

    // ---------------------------------------------------------------------
    // LP actions
    // ---------------------------------------------------------------------

    function deposit(uint256 lpSeed, uint256 amount) external {
        address lp = _lp(lpSeed);
        amount = bound(amount, 1e6, 10_000_000e6);

        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(perps), amount);
        perps.deposit(amount, lp);
        vm.stopPrank();

        calls["deposit"]++;
        _checkOi("deposit");
    }

    function withdraw(uint256 lpSeed, uint256 amount) external {
        address lp = _lp(lpSeed);
        uint256 maxAmount = perps.maxWithdraw(lp);
        if (maxAmount == 0) return;
        amount = bound(amount, 1, maxAmount);

        vm.prank(lp);
        perps.withdraw(amount, lp, lp);

        calls["withdraw"]++;
        _checkOi("withdraw");
    }

    // ---------------------------------------------------------------------
    // Trader actions
    // ---------------------------------------------------------------------

    function increasePosition(uint256 traderSeed, bool isLong, uint256 collateral, uint256 leverage) external {
        address trader = _trader(traderSeed);
        (uint256 sizeInUsd,,,) = _position(trader, isLong);

        // Existing positions can be increased without adding collateral
        collateral = bound(collateral, sizeInUsd == 0 ? 1e6 : 0, 1_000_000e6);
        // Up to 100x so the fuzzer can probe the max leverage (20x) boundary
        leverage = bound(leverage, 1, 100);
        uint256 collateralUsd = (collateral == 0 ? 1e6 : collateral) * perps.getCollateralPrice();
        uint256 sizeDeltaUsd = collateralUsd * leverage;

        usdc.mint(trader, collateral);
        vm.startPrank(trader);
        usdc.approve(address(perps), collateral);
        perps.increasePosition(isLong, sizeDeltaUsd, collateral);
        vm.stopPrank();

        ghost_collateralDeposited[trader] += collateral;

        if (perps.isPositionLiquidatable(trader, isLong)) ghost_openedLiquidatable = true;
        if (_leverage(trader, isLong) > perps.maxLeverage()) ghost_openedAboveMaxLeverage = true;

        calls["increasePosition"]++;
        _checkOi("increasePosition");
    }

    function decreasePosition(uint256 traderSeed, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        address trader = _trader(traderSeed);
        (uint256 sizeInUsd,, uint256 collateralAmount,) = _position(trader, isLong);
        if (sizeInUsd == 0) return;

        sizeDeltaUsd = bound(sizeDeltaUsd, 0, sizeInUsd);
        collateralDelta = bound(collateralDelta, 0, collateralAmount);

        uint256 profit = _expectedProfit(trader, isLong, sizeDeltaUsd);
        uint256 balanceBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        perps.decreasePosition(isLong, sizeDeltaUsd, collateralDelta);

        _recordPayout(trader, usdc.balanceOf(trader) - balanceBefore, profit);

        calls["decreasePosition"]++;
        _checkOi("decreasePosition");
    }

    function liquidate(uint256 traderSeed, bool isLong) external {
        address trader = _trader(traderSeed);
        if (!perps.isPositionLiquidatable(trader, isLong)) return;

        (uint256 sizeInUsd,,,) = _position(trader, isLong);
        uint256 profit = _expectedProfit(trader, isLong, sizeInUsd);
        uint256 balanceBefore = usdc.balanceOf(trader);

        vm.prank(liquidator);
        perps.liquidate(trader, isLong);

        _recordPayout(trader, usdc.balanceOf(trader) - balanceBefore, profit);

        calls["liquidate"]++;
        _checkOi("liquidate");
    }

    // ---------------------------------------------------------------------
    // Environment actions
    // ---------------------------------------------------------------------

    /// @dev Move the BTC price by at most +/-20% per call, within [MIN, MAX].
    function setBtcPrice(uint256 pctSeed, bool up) external {
        uint256 current = uint256(btcFeed.answer());
        uint256 delta = current * bound(pctSeed, 0, 20) / 100;
        uint256 next = up ? current + delta : current - delta;
        next = bound(next, MIN_BTC_PRICE, MAX_BTC_PRICE);
        btcFeed.setPrice(int256(next));

        calls["setBtcPrice"]++;
        _checkOi("setBtcPrice");
    }

    /// @dev Advance time (accrues borrowing fees) and refresh the feeds so the oracle stays fresh.
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 30 days));
        btcFeed.setPrice(btcFeed.answer());
        usdcFeed.setPrice(usdcFeed.answer());

        calls["warp"]++;
    }

    function setBorrowingRate(uint256 rate) external {
        rate = bound(rate, 0, perps.MAX_BORROWING_RATE());
        vm.prank(owner);
        perps.setBorrowingPerSharePerSecond(rate);

        calls["setBorrowingRate"]++;
    }

    // ---------------------------------------------------------------------
    // Views used by the invariant contract
    // ---------------------------------------------------------------------

    function tradersLength() external view returns (uint256) {
        return traders.length;
    }

    function sumPositionCollateral() public view returns (uint256 sum) {
        for (uint256 i; i < traders.length; i++) {
            (,, uint256 cLong,) = perps.longPositions(traders[i]);
            (,, uint256 cShort,) = perps.shortPositions(traders[i]);
            sum += cLong + cShort;
        }
    }

    function sumPositionSizes(bool isLong) public view returns (uint256 usd, uint256 tokens) {
        for (uint256 i; i < traders.length; i++) {
            (uint256 s, uint256 t,,) = _position(traders[i], isLong);
            usd += s;
            tokens += t;
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _lp(uint256 seed) internal view returns (address) {
        return lps[seed % lps.length];
    }

    function _trader(uint256 seed) internal view returns (address) {
        return traders[seed % traders.length];
    }

    function _position(address trader, bool isLong)
        internal
        view
        returns (uint256 sizeInUsd, uint256 sizeInTokens, uint256 collateralAmount, uint256 lastUpdatedAt)
    {
        return isLong ? perps.longPositions(trader) : perps.shortPositions(trader);
    }

    function _leverage(address trader, bool isLong) internal view returns (uint256) {
        (uint256 sizeInUsd,, uint256 collateralAmount,) = _position(trader, isLong);
        if (sizeInUsd == 0) return 0;
        if (collateralAmount == 0) return type(uint256).max;
        return sizeInUsd * 1e30 / (collateralAmount * perps.getCollateralPrice());
    }

    /// @dev Independent re-derivation of the realized profit (in collateral tokens) paid out by
    ///      _decreasePosition, so it can be excluded from "collateral withdrawn".
    function _expectedProfit(address trader, bool isLong, uint256 sizeDeltaUsd) internal view returns (uint256) {
        (uint256 sizeInUsd, uint256 sizeInTokens,,) = _position(trader, isLong);
        if (sizeInUsd == 0) return 0;
        int256 value = int256(sizeInTokens * perps.getIndexPrice());
        int256 totalPnl = isLong ? value - int256(sizeInUsd) : int256(sizeInUsd) - value;
        int256 realized = totalPnl * int256(sizeDeltaUsd) / int256(sizeInUsd);
        return realized > 0 ? uint256(realized) / perps.getCollateralPrice() : 0;
    }

    function _recordPayout(address trader, uint256 received, uint256 profit) internal {
        if (received < profit) {
            ghost_profitUnderpaid = true;
            ghost_profitReceived[trader] += received;
            return;
        }
        ghost_profitReceived[trader] += profit;
        ghost_collateralWithdrawn[trader] += received - profit;
    }

    function _checkOi(string memory action) internal {
        if (bytes(ghost_oiBreachAction).length != 0) return;
        uint256 oi = perps.openInterestLong() + perps.openInterestShort();
        if (oi > perps.totalDeposits() * perps.getCollateralPrice() / 2) ghost_oiBreachAction = action;
    }
}
