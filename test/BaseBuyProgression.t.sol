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

/// @notice Base mainnet fork: buy progression through all 3 bands + fee collection.
///         Run: forge test --match-contract BaseBuyProgressionTest --fork-url https://mainnet.base.org -vvv
contract BaseBuyProgressionTest is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    MindstateToken implementation;
    MindstateLaunchFactory launchFactory;
    MindstateVault vault;
    FeeCollector feeCollector;

    address deployer = address(0xDEAD1);
    address creator  = address(0xC1EA701);
    address buyer1   = address(0xB0B1);
    address buyer2   = address(0xB0B2);
    address buyer3   = address(0xB0B3);

    address mindToken;
    address pool;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setUp() public {
        vm.deal(deployer, 100 ether);
        vm.deal(creator, 10 ether);
        vm.deal(buyer1, 500 ether);
        vm.deal(buyer2, 500 ether);
        vm.deal(buyer3, 500 ether);

        vm.startPrank(deployer);
        implementation = new MindstateToken();
        feeCollector = new FeeCollector(deployer);
        vault = new MindstateVault(POSITION_MANAGER, WETH, deployer);
        launchFactory = new MindstateLaunchFactory(
            address(implementation), WETH, V3_FACTORY, POSITION_MANAGER, deployer
        );
        vault.setFactory(address(launchFactory));
        vault.setFeeCollector(address(feeCollector));
        launchFactory.setVault(address(vault));
        feeCollector.setAuthorizedSource(address(vault), true);
        vm.stopPrank();

        vm.prank(creator);
        (mindToken, pool) = launchFactory.launch(
            "Mind", "MIND", 100e18, IMindstate.RedeemMode.PerCheckpoint
        );

        console.log("=== MIND Token Launched on Base Fork ===");
        console.log("Token:  ", mindToken);
        console.log("Pool:   ", pool);
        console.log("Token is token0:", mindToken < WETH);
        console.log("Supply: 1,000,000,000 MIND");
        console.log("");
    }

    function _wrapETH(address who, uint256 amount) internal {
        vm.prank(who);
        (bool ok,) = WETH.call{value: amount}("");
        require(ok, "WETH wrap failed");
    }

    function _buyMind(address buyer, uint256 wethAmount) internal returns (uint256 tokensOut) {
        _wrapETH(buyer, wethAmount);
        vm.startPrank(buyer);
        IERC20(WETH).approve(SWAP_ROUTER, wethAmount);
        bytes memory callData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: mindToken,
                fee: 10000,
                recipient: buyer,
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

    function _getMarketCap() internal view returns (uint256 mcapWei, uint256 priceWeiPerToken) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        bool wethIsToken0 = WETH < mindToken;
        uint256 sqrtP = uint256(sqrtPriceX96);

        if (wethIsToken0) {
            uint256 inv = (1e18 * (1 << 96)) / sqrtP;
            priceWeiPerToken = (inv * (1 << 96)) / sqrtP;
        } else {
            uint256 half = (sqrtP * 1e9) / (1 << 96);
            priceWeiPerToken = half * half;
        }
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

    uint256 cumulative;

    function _buy(address buyer, uint256 amount, string memory label) internal {
        uint256 tokensOut = _buyMind(buyer, amount);
        cumulative += amount;
        console.log(label);
        console.log("  ETH in:    ", amount / 1e15, "finney");
        console.log("  Tokens out:", tokensOut / 1e18, "MIND");
        _logState(label, cumulative);
    }

    function test_buyProgression() public {
        _logState("INITIAL (post-launch)", 0);

        _buy(buyer1, 0.01 ether,  "Buy  1: 0.01 ETH");
        _buy(buyer1, 0.1 ether,   "Buy  2: 0.1 ETH");
        _buy(buyer1, 0.5 ether,   "Buy  3: 0.5 ETH");
        _buy(buyer2, 1 ether,     "Buy  4: 1 ETH");
        _buy(buyer2, 2 ether,     "Buy  5: 2 ETH");
        _buy(buyer2, 3 ether,     "Buy  6: 3 ETH");
        _buy(buyer3, 5 ether,     "Buy  7: 5 ETH");
        _buy(buyer3, 5 ether,     "Buy  8: 5 ETH");
        _buy(buyer3, 10 ether,    "Buy  9: 10 ETH");
        _buy(buyer3, 10 ether,    "Buy 10: 10 ETH");
        _buy(buyer1, 15 ether,    "Buy 11: 15 ETH");
        _buy(buyer1, 20 ether,    "Buy 12: 20 ETH");
        _buy(buyer2, 25 ether,    "Buy 13: 25 ETH");
        _buy(buyer2, 30 ether,    "Buy 14: 30 ETH");
        _buy(buyer3, 40 ether,    "Buy 15: 40 ETH");
        _buy(buyer3, 50 ether,    "Buy 16: 50 ETH");
        _buy(buyer1, 50 ether,    "Buy 17: 50 ETH");
        _buy(buyer2, 75 ether,    "Buy 18: 75 ETH");
        _buy(buyer3, 100 ether,   "Buy 19: 100 ETH");
        _buy(buyer1, 100 ether,   "Buy 20: 100 ETH");

        console.log("=== BUY PROGRESSION COMPLETE ===");
        console.log("Total ETH spent:", cumulative / 1e18);
        (uint256 finalMcap,) = _getMarketCap();
        console.log("Final mcap (ETH):", finalMcap / 1e18);
    }

    function test_feeCollection() public {
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

        if (creatorEarned > 0 && platformEarned > 0) {
            uint256 ratio = (creatorEarned * 100) / (creatorEarned + platformEarned);
            console.log("  Creator / (Creator+Platform):", ratio, "%");
            assertApproxEqAbs(ratio, 80, 2);
        }

        MindstateVault.Position memory pos = vault.getPosition(mindToken);
        console.log("  Vault totalWethCollected:", pos.totalWethCollected / 1e15, "finney");
        assertGt(pos.totalWethCollected, 0);
    }
}
