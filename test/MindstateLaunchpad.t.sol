// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MindstateToken} from "../src/MindstateToken.sol";
import {MindstateLaunchFactory} from "../src/launchpad/MindstateLaunchFactory.sol";
import {MindstateVault} from "../src/launchpad/MindstateVault.sol";
import {FeeCollector} from "../src/launchpad/FeeCollector.sol";
import {IMindstate} from "../src/interfaces/IMindstate.sol";
import {IUniswapV3Pool} from "../src/launchpad/interfaces/IUniswapV3.sol";

/// @title MindstateLaunchpadTest
/// @notice Fork test: deploy the full launchpad stack on an Ethereum mainnet fork,
///         launch a "MIND" token, perform multiple buys at increasing sizes, and
///         verify market cap progression + fee collection at each interval.
///
///         Run with:
///           forge test --match-contract MindstateLaunchpadTest --fork-url $ETH_RPC -vvv
contract MindstateLaunchpadTest is Test {
    // ── Mainnet addresses ────────────────────────────────────
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // ── Protocol contracts ───────────────────────────────────
    MindstateToken implementation;
    MindstateLaunchFactory launchFactory;
    MindstateVault vault;
    FeeCollector feeCollector;

    // ── Actors ───────────────────────────────────────────────
    address deployer = address(0xDEAD1);
    address creator  = address(0xC1EA701);
    address buyer1   = address(0xB0B1);
    address buyer2   = address(0xB0B2);
    address buyer3   = address(0xB0B3);

    // ── Launch results ───────────────────────────────────────
    address mindToken;
    address pool;

    // ── Swap router interface (minimal) ──────────────────────
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setUp() public {
        // Fund actors with ETH
        vm.deal(deployer, 100 ether);
        vm.deal(creator, 10 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(buyer3, 500 ether);

        // ── Deploy protocol stack ────────────────────────────
        vm.startPrank(deployer);

        implementation = new MindstateToken();
        feeCollector = new FeeCollector(deployer);
        vault = new MindstateVault(POSITION_MANAGER, WETH, deployer);
        launchFactory = new MindstateLaunchFactory(
            address(implementation),
            WETH,
            V3_FACTORY,
            POSITION_MANAGER,
            deployer
        );

        // Wire contracts
        vault.setFactory(address(launchFactory));
        vault.setFeeCollector(address(feeCollector));
        launchFactory.setVault(address(vault));
        feeCollector.setAuthorizedSource(address(vault), true);

        vm.stopPrank();

        // ── Launch MIND token ────────────────────────────────
        vm.prank(creator);
        (mindToken, pool) = launchFactory.launch(
            "Mind",
            "MIND",
            100e18,   // 100 tokens burned per redemption
            IMindstate.RedeemMode.PerCheckpoint
        );

        console.log("=== MIND Token Launched ===");
        console.log("Token:  ", mindToken);
        console.log("Pool:   ", pool);
        console.log("Supply: 1,000,000,000 MIND");
        console.log("");
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    /// @dev Wrap ETH to WETH for a given address.
    function _wrapETH(address who, uint256 amount) internal {
        vm.prank(who);
        (bool ok,) = WETH.call{value: amount}("");
        require(ok, "WETH deposit failed");
    }

    /// @dev Buy MIND tokens with WETH via the V3 SwapRouter.
    function _buyMind(address buyer, uint256 wethAmount) internal returns (uint256 tokensOut) {
        _wrapETH(buyer, wethAmount);

        vm.startPrank(buyer);
        IERC20(WETH).approve(SWAP_ROUTER, wethAmount);

        bytes memory callData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: mindToken,
                fee: 10000, // 1%
                recipient: buyer,
                deadline: block.timestamp,
                amountIn: wethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (bool ok, bytes memory ret) = SWAP_ROUTER.call(callData);
        require(ok, "Swap failed");
        tokensOut = abi.decode(ret, (uint256));

        vm.stopPrank();
    }

    /// @dev Read the current token price from the pool's slot0 and compute market cap.
    function _getMarketCap() internal view returns (uint256 mcapWei, uint256 priceWeiPerToken) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        bool wethIsToken0 = WETH < mindToken;

        // V3 price = (sqrtPriceX96 / 2^96)^2
        // We compute price * 1e18 for precision.
        uint256 sqrtP = uint256(sqrtPriceX96);

        if (wethIsToken0) {
            // V3 price = tokens/WETH → token price = 1/price in WETH
            // price_tokens_per_weth = sqrtP^2 / 2^192
            // price_weth_per_token = 2^192 / sqrtP^2
            // To avoid overflow: (1e18 * 2^192) / sqrtP^2
            // Split: (1e18 * 2^96 / sqrtP) * (2^96 / sqrtP)
            uint256 inv = (1e18 * (1 << 96)) / sqrtP;
            priceWeiPerToken = (inv * (1 << 96)) / sqrtP;
        } else {
            // V3 price = WETH/token → token price directly
            // price = sqrtP^2 / 2^192, scaled by 1e18
            // Split: (sqrtP * 1e9 / 2^96) ^ 2
            uint256 half = (sqrtP * 1e9) / (1 << 96);
            priceWeiPerToken = half * half;
        }

        // Market cap = price per token * total supply (1B)
        mcapWei = (priceWeiPerToken * 1_000_000_000);
    }

    function _logState(string memory label, uint256 ethSpent) internal view {
        (uint256 mcapWei, uint256 priceWei) = _getMarketCap();
        uint256 buyerBalance = IERC20(mindToken).balanceOf(buyer1)
            + IERC20(mindToken).balanceOf(buyer2)
            + IERC20(mindToken).balanceOf(buyer3);

        console.log("---", label, "---");
        console.log("  ETH spent (cumulative):", ethSpent / 1e15, "finney");
        console.log("  Price (wei/token):     ", priceWei);
        console.log("  Market cap (ETH):      ", mcapWei / 1e18);
        console.log("  Tokens held by buyers: ", buyerBalance / 1e18);
        console.log("");
    }

    // =====================================================================
    //  Shared state for sequential test execution
    // =====================================================================

    uint256 cumulative;

    function _buy(address buyer, uint256 amount, string memory label) internal {
        uint256 tokensOut = _buyMind(buyer, amount);
        cumulative += amount;
        console.log(label);
        console.log("  ETH in:    ", amount / 1e15, "finney");
        console.log("  Tokens out:", tokensOut / 1e18, "MIND");
        _logState(label, cumulative);
    }

    // =====================================================================
    //  Main test: buy progression through bands
    // =====================================================================

    function test_buyProgression() public {
        _logState("INITIAL (post-launch)", 0);

        _buy(buyer1, 0.01 ether,  "Buy 1: 0.01 ETH");
        _buy(buyer1, 0.1 ether,   "Buy 2: 0.1 ETH");
        _buy(buyer2, 1 ether,     "Buy 3: 1 ETH");
        _buy(buyer2, 5 ether,     "Buy 4: 5 ETH (approaching band 1 graduation)");
        _buy(buyer3, 10 ether,    "Buy 5: 10 ETH (into band 2)");
        _buy(buyer3, 25 ether,    "Buy 6: 25 ETH (deep into band 2)");
        _buy(buyer3, 50 ether,    "Buy 7: 50 ETH (whale buy)");

        console.log("=== BUY PROGRESSION COMPLETE ===");
        console.log("Total ETH spent:", cumulative / 1e18);
        (uint256 finalMcap,) = _getMarketCap();
        console.log("Final mcap (ETH):", finalMcap / 1e18);
    }

    // =====================================================================
    //  Fee collection test
    // =====================================================================

    function test_feeCollection() public {
        // Generate trading volume first
        _buy(buyer1, 1 ether,  "Setup buy 1");
        _buy(buyer2, 5 ether,  "Setup buy 2");
        _buy(buyer3, 20 ether, "Setup buy 3");

        console.log("=== FEE COLLECTION ===");

        uint256 creatorBefore = IERC20(WETH).balanceOf(creator);
        uint256 platformBefore = IERC20(WETH).balanceOf(address(feeCollector));

        vault.collectFees(mindToken);

        uint256 creatorEarned = IERC20(WETH).balanceOf(creator) - creatorBefore;
        uint256 platformEarned = IERC20(WETH).balanceOf(address(feeCollector)) - platformBefore;

        console.log("  Creator WETH (60%):", creatorEarned / 1e15, "finney");
        console.log("  Platform WETH (15%):", platformEarned / 1e15, "finney");

        assertGt(creatorEarned, 0, "Creator should earn fees");
        assertGt(platformEarned, 0, "Platform should earn fees");

        // 60/(60+15) = 80% of the non-burn portion
        if (creatorEarned > 0 && platformEarned > 0) {
            uint256 ratio = (creatorEarned * 100) / (creatorEarned + platformEarned);
            console.log("  Creator / (Creator+Platform):", ratio, "%");
            assertApproxEqAbs(ratio, 80, 2);
        }

        // Vault accounting
        MindstateVault.Position memory pos = vault.getPosition(mindToken);
        console.log("  Vault totalWethCollected:", pos.totalWethCollected / 1e15, "finney");
        assertGt(pos.totalWethCollected, 0);
    }

    // =====================================================================
    //  Verify 3 band positions exist
    // =====================================================================

    function test_threeBandsRegistered() public {
        uint256[3] memory ids = vault.getTokenIds(mindToken);
        console.log("Band 1 NFT ID:", ids[0]);
        console.log("Band 2 NFT ID:", ids[1]);
        console.log("Band 3 NFT ID:", ids[2]);
        assertGt(ids[0], 0, "Band 1 should exist");
        assertGt(ids[1], 0, "Band 2 should exist");
        assertGt(ids[2], 0, "Band 3 should exist");
    }

    // =====================================================================
    //  Double collection reverts
    // =====================================================================

    function test_doubleCollectionReverts() public {
        // Generate fees
        _buy(buyer1, 1 ether, "Generate fees");
        vault.collectFees(mindToken);

        // Second collection should revert
        vm.expectRevert(MindstateVault.NoFeesToCollect.selector);
        vault.collectFees(mindToken);
    }
}
