// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";
import {IFeeCollector} from "./interfaces/IMindstateLaunchpad.sol";

/// @title MindstateVault
/// @notice Holds Uniswap V3 LP NFT positions for all launched Mindstate tokens.
///         Each launch creates 3 concentrated liquidity bands. The vault holds all
///         3 LP NFTs permanently. Anyone can trigger fee collection; fees are
///         distributed as: 60% creator / 25% burn / 15% platform.
contract MindstateVault is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Number of liquidity bands per launch
    uint256 public constant NUM_BANDS = 3;

    /// @notice Creator's share of collected fees (60%)
    uint256 public constant CREATOR_SHARE = 6000;

    /// @notice Burn share of collected fees (25%)
    uint256 public constant BURN_SHARE = 2500;

    /// @notice Platform share of collected fees (15%)
    uint256 public constant PLATFORM_SHARE = 1500;

    /// @notice Dead address for burns
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ============ Immutables ============

    /// @notice The Uniswap V3 NonfungiblePositionManager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice The WETH address (fee token)
    address public immutable WETH;

    // ============ State ============

    /// @notice Position data per launched token (holds 3 band NFTs)
    struct Position {
        uint256[3] tokenIds;     // V3 LP NFT token IDs (one per band)
        address creator;         // Publisher — receives 60% of fees
        address pool;            // V3 pool address
        uint256 totalWethCollected;
        uint256 totalTokenCollected;
    }

    /// @notice Launched token address => position data
    mapping(address => Position) public positions;

    /// @notice Token ID => launched token address (reverse lookup)
    mapping(uint256 => address) public tokenIdToLaunch;

    /// @notice Fee collector address (platform's 15%)
    address public feeCollector;

    /// @notice Factory address (only factory can register positions)
    address public factory;

    // ============ Events ============

    event PositionsRegistered(
        address indexed token,
        address indexed creator,
        address indexed pool,
        uint256[3] tokenIds
    );
    event FeesCollected(address indexed token, uint256 wethAmount, uint256 tokenAmount);
    event FeesDistributed(address indexed token, uint256 creatorShare, uint256 burnShare, uint256 platformShare);
    event FactoryUpdated(address indexed factory);
    event FeeCollectorUpdated(address indexed feeCollector);

    // ============ Errors ============

    error OnlyFactory();
    error PositionNotFound();
    error NoFeesToCollect();
    error FeeCollectorNotSet();
    error AlreadyRegistered();

    // ============ Constructor ============

    constructor(
        address _positionManager,
        address _weth,
        address _owner
    ) Ownable(_owner) {
        require(_positionManager != address(0), "Invalid position manager");
        require(_weth != address(0), "Invalid WETH");
        positionManager = INonfungiblePositionManager(_positionManager);
        WETH = _weth;
    }

    // ============ Admin ============

    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory");
        factory = _factory;
        emit FactoryUpdated(_factory);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Invalid fee collector");
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector);
    }

    // ============ Position Registration ============

    /// @notice Register 3 LP positions for a launched token (called by factory)
    /// @dev All 3 NFTs must already be transferred to this vault before calling
    /// @param token The launched Mindstate token address
    /// @param tokenIds The 3 V3 LP NFT token IDs (one per band)
    /// @param creator The publisher/creator address
    /// @param pool The V3 pool address
    function registerPositions(
        address token,
        uint256[3] calldata tokenIds,
        address creator,
        address pool
    ) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (positions[token].tokenIds[0] != 0) revert AlreadyRegistered();

        for (uint256 i = 0; i < NUM_BANDS; i++) {
            require(tokenIds[i] != 0, "Invalid token ID");
            require(positionManager.ownerOf(tokenIds[i]) == address(this), "Vault must own NFT");
            tokenIdToLaunch[tokenIds[i]] = token;
        }

        positions[token] = Position({
            tokenIds: tokenIds,
            creator: creator,
            pool: pool,
            totalWethCollected: 0,
            totalTokenCollected: 0
        });

        emit PositionsRegistered(token, creator, pool, tokenIds);
    }

    // ============ Fee Collection ============

    /// @notice Collect accumulated trading fees from all 3 band positions and
    ///         distribute them. Anyone can call this — it's permissionless.
    /// @param token The launched Mindstate token address
    function collectFees(address token) external nonReentrant {
        if (feeCollector == address(0)) revert FeeCollectorNotSet();
        Position storage pos = positions[token];
        if (pos.tokenIds[0] == 0) revert PositionNotFound();

        uint256 totalAmount0;
        uint256 totalAmount1;

        for (uint256 i = 0; i < NUM_BANDS; i++) {
            if (pos.tokenIds[i] == 0) continue;

            (uint256 a0, uint256 a1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: pos.tokenIds[i],
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            totalAmount0 += a0;
            totalAmount1 += a1;
        }

        if (totalAmount0 == 0 && totalAmount1 == 0) revert NoFeesToCollect();

        uint256 wethAmount;
        uint256 tokenAmount;
        if (_isToken0WETH(token)) {
            wethAmount = totalAmount0;
            tokenAmount = totalAmount1;
        } else {
            wethAmount = totalAmount1;
            tokenAmount = totalAmount0;
        }

        pos.totalWethCollected += wethAmount;
        pos.totalTokenCollected += tokenAmount;

        emit FeesCollected(token, wethAmount, tokenAmount);

        if (wethAmount > 0) {
            _distributeWethFees(token, pos.creator, wethAmount);
        }

        if (tokenAmount > 0) {
            IERC20(token).safeTransfer(BURN_ADDRESS, tokenAmount);
        }
    }

    function _distributeWethFees(address token, address creator, uint256 wethAmount) internal {
        uint256 creatorAmount = (wethAmount * CREATOR_SHARE) / 10000;
        uint256 burnAmount = (wethAmount * BURN_SHARE) / 10000;
        uint256 platformAmount = wethAmount - creatorAmount - burnAmount;

        if (creatorAmount > 0) {
            IERC20(WETH).safeTransfer(creator, creatorAmount);
        }

        if (burnAmount > 0) {
            IERC20(WETH).safeTransfer(BURN_ADDRESS, burnAmount);
        }

        if (platformAmount > 0) {
            IERC20(WETH).safeTransfer(feeCollector, platformAmount);
            IFeeCollector(feeCollector).receiveFees(WETH, platformAmount);
        }

        emit FeesDistributed(token, creatorAmount, burnAmount, platformAmount);
    }

    function _isToken0WETH(address token) internal view returns (bool) {
        return WETH < token;
    }

    // ============ Views ============

    /// @notice Get position info for a launched token
    function getPosition(address token) external view returns (Position memory) {
        return positions[token];
    }

    /// @notice Get all 3 V3 LP NFT token IDs for a launched token
    function getTokenIds(address token) external view returns (uint256[3] memory) {
        return positions[token].tokenIds;
    }

    // ============ ERC721 Receiver ============

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
