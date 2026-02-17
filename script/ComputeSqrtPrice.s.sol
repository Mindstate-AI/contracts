// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @notice Compute the correct sqrtPriceX96 values for Mindstate pool initialization.
///
///         Target: $3K market cap with 1B supply at $2000/ETH
///           → 1 token = 1.5e-9 WETH
///           → 1 WETH  = 6.667e8 tokens
///
///         V3 price is always token1/token0 in smallest units (wei).
///         Both tokens have 18 decimals so raw price = human price.
///
///         When WETH is token0: price = Mindstate/WETH = 6.667e8
///           tick ≈ +203,200 (positive, tokens are cheap relative to WETH)
///
///         When token is token0: price = WETH/Mindstate = 1.5e-9
///           tick ≈ -203,200 (negative, same relationship)
contract ComputeSqrtPrice is Script {
    function run() external pure {
        // Target tick: approximately 203200 (aligned to tickSpacing=200)
        // We compute sqrtPriceX96 = sqrt(1.0001^tick) * 2^96

        // For WETH is token0 (tick = +203200):
        //   price = 1.0001^203200
        //   sqrtPrice = 1.0001^(203200/2) = 1.0001^101600
        //   sqrtPriceX96 = sqrtPrice * 2^96

        // For token is token0 (tick = -203200):
        //   price = 1.0001^(-203200)
        //   sqrtPrice = 1.0001^(-101600)
        //   sqrtPriceX96 = sqrtPrice * 2^96

        // Using the identity: 1.0001^n = exp(n * ln(1.0001))
        // ln(1.0001) ≈ 0.000099995000333...

        // Method: compute via tick → sqrtRatio relationship
        // sqrtPriceX96 = sqrt(1.0001^tick) * 2^96

        // For tick = 203200:
        //   1.0001^203200 = exp(203200 * 0.000099995) = exp(20.319) ≈ 6.628e8
        //   sqrt(6.628e8) = 25745.3
        //   sqrtPriceX96 = 25745.3 * 2^96

        // 2^96 = 79228162514264337593543950336
        // 25745 * 79228162514264337593543950336 = 2,040,331,523,484,774,058,083,197,806,252,320

        // But we need exact alignment. Let's use tick = 203200 exactly.
        // From Uniswap TickMath: getSqrtRatioAtTick(203200)

        // We can compute this precisely using the TickMath approach.
        // For now, let's verify by computing from the target price.

        // ═══════════════════════════════════════════════════════════
        //  WETH IS TOKEN0 (positive ticks)
        // ═══════════════════════════════════════════════════════════
        //
        // Target price: ~6.667e8 (tokens per WETH)
        // Using 1 WETH = 666,666,667 tokens (for $3K mcap at $2K ETH, 1B supply)
        //
        // sqrtPriceX96 = sqrt(666666667) * 2^96
        //              = 25820.0 * 79228162514264337593543950336
        //
        // Let's compute: 25820 * 79228162514264337593543950336
        uint256 Q96 = 2**96;

        // sqrt(666666667) ≈ 25820.10 (we use integer sqrt)
        // More precisely: 25820^2 = 666,672,400 (close to 666,666,667)
        // 25819^2 = 666,620,561
        // Better: use 25820 as approximation

        // Precise computation using fixed-point:
        // price = 666666667 (in Q0 — raw integer ratio)
        // sqrtPrice (Q96) = sqrt(price) * 2^96
        // = isqrt(price * 2^192)
        // = isqrt(666666667 * 2^192)

        // For the script output, let's just compute the values:
        console.log("=== sqrtPriceX96 Computation ===");
        console.log("");

        // We need the initial tick to be OUTSIDE the Band 1 range:
        //   - WETH is token0: tick must be > TICK_BOUND_0 (203200) → token1 zone
        //   - Token is token0: tick must be < -TICK_BOUND_0 (-203200) → token0 zone
        //
        // Using sqrt(price) ≈ 25830 gives price = 25830^2 = 667,188,900
        // which corresponds to tick ≈ 203,208 (just above 203,200). ✓

        uint256 SQRT_INT = 25840;

        uint256 sqrtWethIsToken0 = SQRT_INT * Q96;
        console.log("INIT_SQRT_PRICE_WETH_IS_TOKEN0 =", sqrtWethIsToken0);
        console.log("  price (token1/token0):", SQRT_INT * SQRT_INT);
        console.log("");

        uint256 sqrtTokenIsToken0 = (Q96 * Q96) / sqrtWethIsToken0;
        console.log("INIT_SQRT_PRICE_TOKEN_IS_TOKEN0 =", sqrtTokenIsToken0);
        console.log("  price = 1 /", SQRT_INT * SQRT_INT);
        console.log("");

        console.log("=== Old (buggy) values for comparison ===");
        console.log("  Old WETH_IS_TOKEN0:  2045830200901498806034432");
        console.log("  Old TOKEN_IS_TOKEN0: 3068745301352248");
    }
}
