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

/// @notice Base mainnet fork test to verify sqrtPriceX96 fix.
///         Run: forge test --match-contract BaseForkTest --fork-url https://mainnet.base.org -vvv
contract BaseForkTest is Test {
    // Base mainnet addresses
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
    address buyer    = address(0xB0B1);

    address token;
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
        vm.deal(buyer, 100 ether);

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
    }

    function test_launchOnBase() public {
        // Verify WETH is token0 (lower address) on Base
        console.log("WETH address:", WETH);
        console.log("WETH < 0x5000...:", WETH < address(0x5000000000000000000000000000000000000000));

        vm.prank(creator);
        (token, pool) = launchFactory.launch(
            "Test", "TEST", 100e18, IMindstate.RedeemMode.PerCheckpoint
        );

        console.log("Token:", token);
        console.log("Pool: ", pool);
        console.log("WETH is token0:", WETH < token);

        // Log ordering — either is fine, the factory handles both
        console.log("Token is token0:", token < WETH);

        // Verify 3 bands
        uint256[3] memory ids = vault.getTokenIds(token);
        assertGt(ids[0], 0, "Band 1 exists");
        assertGt(ids[1], 0, "Band 2 exists");
        assertGt(ids[2], 0, "Band 3 exists");
        console.log("Band 1 NFT:", ids[0]);
        console.log("Band 2 NFT:", ids[1]);
        console.log("Band 3 NFT:", ids[2]);

        // Read pool price
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        console.log("Initial sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("Initial tick:", tick);

        // Buy some tokens
        uint256 tokensOut = _buy(buyer, 0.01 ether);
        console.log("Bought tokens (0.01 ETH):", tokensOut / 1e18, "TEST");
        assertGt(tokensOut, 0, "Should receive tokens");
    }

    function _buy(address who, uint256 wethAmount) internal returns (uint256) {
        vm.deal(who, wethAmount);
        vm.startPrank(who);
        (bool ok,) = WETH.call{value: wethAmount}("");
        require(ok, "WETH wrap failed");
        IERC20(WETH).approve(SWAP_ROUTER, wethAmount);

        bytes memory callData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: token,
                fee: 10000,
                recipient: who,
                amountIn: wethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (bool swapOk, bytes memory ret) = SWAP_ROUTER.call(callData);
        require(swapOk, "Swap failed");
        vm.stopPrank();
        return abi.decode(ret, (uint256));
    }
}
