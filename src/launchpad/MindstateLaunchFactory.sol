// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";
import {MindstateToken} from "../MindstateToken.sol";
import {IMindstate} from "../interfaces/IMindstate.sol";

interface IMindstateVault {
    function registerPositions(address token, uint256[3] calldata tokenIds, address creator, address pool) external;
}

/// @title MindstateLaunchFactory
/// @notice Creates new Mindstate token launches with Uniswap V3 liquidity.
///
///         Each launch deploys an EIP-1167 clone of MindstateToken, creates a V3 pool
///         (token/WETH, 1% fee tier), seeds all tokens as single-sided liquidity, and
///         transfers the LP NFT to the MindstateVault for permanent custody.
///
///         The publisher retains checkpoint authority. Trading fees accumulate in the
///         V3 position and are distributed by the vault (60% creator / 25% burn / 15% platform).
contract MindstateLaunchFactory is Ownable2Step, ReentrancyGuard {
    using Clones for address;

    // ============ Constants ============

    /// @notice Default total supply for launched tokens (1 billion)
    uint256 public constant DEFAULT_TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice V3 fee tier: 1% (10000 bps)
    uint24 public constant POOL_FEE = 10000;

    /// @notice Tick spacing for 1% fee tier
    int24 public constant TICK_SPACING = 200;

    // ---- 3-Band Liquidity Distribution (60 / 25 / 15) -----------------------
    //
    // Band 1 (Graduation):  $3K → $100K mcap, 60% supply, ~5 ETH to clear
    // Band 2 (Growth):      $100K → $1M mcap, 25% supply
    // Band 3 (Discovery):   $1M → $100M mcap, 15% supply (thin tail)
    //
    // Token price boundaries (WETH/token at $2K ETH):
    //   $3K mcap   → 1.5e-9  WETH/token
    //   $100K mcap → 5e-8    WETH/token
    //   $1M mcap   → 5e-7    WETH/token
    //   $100M mcap → 5e-5    WETH/token
    //
    // Ticks are pre-computed and aligned to tick spacing (200).
    // Sign depends on token ordering — see _seedPool for the flip logic.
    //
    // When token < WETH (token is token0), V3 price = WETH/token:
    //   Higher token price → higher tick (positive direction)
    //   Ticks are negative since WETH/token < 1.
    //
    // When WETH < token (WETH is token0), V3 price = tokens/WETH:
    //   Higher token price → lower V3 price → lower tick
    //   Ticks are positive since tokens/WETH > 1.

    /// @notice Band supply splits in basis points (must sum to 10000)
    uint256 public constant BAND1_BPS = 6000;  // 60% — graduation
    uint256 public constant BAND2_BPS = 2500;  // 25% — growth
    uint256 public constant BAND3_BPS = 1500;  // 15% — discovery

    /// @notice Tick boundaries (absolute values, aligned to tick spacing 200).
    ///         Applied as positive when WETH is token0, negative when token is token0.
    int24 public constant TICK_BOUND_0 = 203200;  // $3K mcap (cheapest)
    int24 public constant TICK_BOUND_1 = 168200;  // $100K mcap
    int24 public constant TICK_BOUND_2 = 145200;  // $1M mcap
    int24 public constant TICK_BOUND_3 = 99200;   // $100M mcap (most expensive)

    /// @notice sqrtPriceX96 for pool initialization at the Band 1 floor ($3K mcap).
    ///         When WETH is token0: price = tokens/WETH ≈ 6.67e8
    ///           sqrtPriceX96 = sqrt(6.67e8) * 2^96 ≈ 2.045e21
    uint160 public constant INIT_SQRT_PRICE_WETH_IS_TOKEN0 = 2045830200901498806034432;
    ///         When token is token0: price = WETH/token ≈ 1.5e-9
    ///           sqrtPriceX96 = sqrt(1.5e-9) * 2^96 ≈ 3.068e12
    uint160 public constant INIT_SQRT_PRICE_TOKEN_IS_TOKEN0 = 3068745301352248;

    // ============ Immutables ============

    /// @notice Address of the canonical MindstateToken implementation contract.
    address public immutable IMPLEMENTATION;

    /// @notice WETH address (quote token)
    address public immutable WETH;

    /// @notice Uniswap V3 Factory
    IUniswapV3Factory public immutable v3Factory;

    /// @notice Uniswap V3 NonfungiblePositionManager
    INonfungiblePositionManager public immutable positionManager;

    // ============ Configuration ============

    /// @notice The MindstateVault address (receives LP NFTs)
    address public vault;

    /// @notice Paused state
    bool public paused;

    /// @notice Authorized launch agents (can launch on behalf of creators)
    mapping(address => bool) public isLaunchAgent;

    // ============ State ============

    /// @notice Launch data
    struct Launch {
        address token;               // Mindstate token address
        address creator;             // Publisher — checkpoint authority + fee recipient
        uint256 tokenSupply;
        uint256 redeemCost;          // Tokens burned per redemption
        IMindstate.RedeemMode redeemMode;
        address pool;                // V3 pool address
        uint256 createdAt;
        string name;
        string symbol;
    }

    /// @notice All launches by token address
    mapping(address => Launch) public launches;

    /// @notice Array of all launched token addresses
    address[] public allLaunches;

    /// @notice Check if token was launched via this factory
    mapping(address => bool) public isLaunch;

    /// @notice Creator address => list of tokens they launched
    mapping(address => address[]) private _creatorTokens;

    // ============ Events ============

    event MindstateLaunched(
        address indexed token,
        address indexed creator,
        address indexed pool,
        string name,
        string symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    );

    event VaultUpdated(address indexed vault);
    event LaunchAgentUpdated(address indexed agent, bool authorized);

    // ============ Errors ============

    error Paused();
    error InvalidName();
    error InvalidSymbol();
    error InvalidAmount();
    error InvalidCreator();
    error VaultNotSet();
    error NotLaunchAgent();

    // ============ Modifiers ============

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _implementation,
        address _weth,
        address _v3Factory,
        address _positionManager,
        address _owner
    ) Ownable(_owner) {
        require(_implementation != address(0), "Invalid implementation");
        require(_weth != address(0), "Invalid WETH");
        require(_v3Factory != address(0), "Invalid V3 factory");
        require(_positionManager != address(0), "Invalid position manager");

        IMPLEMENTATION = _implementation;
        WETH = _weth;
        v3Factory = IUniswapV3Factory(_v3Factory);
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    // ============ Admin Functions ============

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "Invalid vault");
        vault = _vault;
        emit VaultUpdated(_vault);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @notice Authorize or revoke a launch agent
    function setLaunchAgent(address agent, bool authorized) external onlyOwner {
        require(agent != address(0), "Invalid agent");
        isLaunchAgent[agent] = authorized;
        emit LaunchAgentUpdated(agent, authorized);
    }

    // ============ Launch Functions ============

    /// @notice Launch a new Mindstate token with Uniswap V3 liquidity.
    ///         The caller becomes the publisher (checkpoint authority + fee recipient).
    function launch(
        string calldata name,
        string calldata symbol,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    ) external nonReentrant whenNotPaused returns (address token, address pool) {
        return _launch(name, symbol, DEFAULT_TOTAL_SUPPLY, redeemCost, redeemMode, msg.sender);
    }

    /// @notice Launch with custom supply
    function launchWithSupply(
        string calldata name,
        string calldata symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    ) external nonReentrant whenNotPaused returns (address token, address pool) {
        if (tokenSupply == 0) revert InvalidAmount();
        return _launch(name, symbol, tokenSupply, redeemCost, redeemMode, msg.sender);
    }

    /// @notice Launch on behalf of a creator (agent-only)
    function launchFor(
        string calldata name,
        string calldata symbol,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode,
        address creator
    ) external nonReentrant whenNotPaused returns (address token, address pool) {
        if (!isLaunchAgent[msg.sender]) revert NotLaunchAgent();
        if (creator == address(0)) revert InvalidCreator();
        return _launch(name, symbol, DEFAULT_TOTAL_SUPPLY, redeemCost, redeemMode, creator);
    }

    /// @notice Launch on behalf of a creator with custom supply (agent-only)
    function launchForWithSupply(
        string calldata name,
        string calldata symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode,
        address creator
    ) external nonReentrant whenNotPaused returns (address token, address pool) {
        if (!isLaunchAgent[msg.sender]) revert NotLaunchAgent();
        if (creator == address(0)) revert InvalidCreator();
        if (tokenSupply == 0) revert InvalidAmount();
        return _launch(name, symbol, tokenSupply, redeemCost, redeemMode, creator);
    }

    function _launch(
        string calldata name,
        string calldata symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode,
        address creator
    ) internal returns (address token, address pool) {
        // Validate inputs
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidName();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 12) revert InvalidSymbol();
        if (vault == address(0)) revert VaultNotSet();

        // 1. Deploy MindstateToken clone — supply minted to this factory
        token = IMPLEMENTATION.clone();
        MindstateToken(token).initializeForLaunch(
            creator,          // publisher — checkpoint authority
            address(this),    // mintTo — factory holds supply temporarily
            name,
            symbol,
            tokenSupply,
            redeemCost,
            redeemMode
        );

        // 2. Create V3 pool and seed 3-band concentrated liquidity
        pool = _seedPool(token, tokenSupply, creator);

        // 3. Store launch data
        launches[token] = Launch({
            token: token,
            creator: creator,
            tokenSupply: tokenSupply,
            redeemCost: redeemCost,
            redeemMode: redeemMode,
            pool: pool,
            createdAt: block.timestamp,
            name: name,
            symbol: symbol
        });

        allLaunches.push(token);
        isLaunch[token] = true;
        _creatorTokens[creator].push(token);

        emit MindstateLaunched(token, creator, pool, name, symbol, tokenSupply, redeemCost, redeemMode);
    }

    /// @dev Packed seed parameters to avoid stack-too-deep in _seedPool.
    struct SeedParams {
        address token0;
        address token1;
        bool wethIsToken0;
        address pool;
    }

    /// @notice Create a V3 pool, initialize it at the Band 1 floor price, mint
    ///         3 concentrated liquidity positions (one per band), and transfer
    ///         all LP NFTs to the vault for permanent custody.
    function _seedPool(address token, uint256 tokenSupply, address creator) internal returns (address pool) {
        SeedParams memory p;
        p.wethIsToken0 = WETH < token;
        (p.token0, p.token1) = p.wethIsToken0
            ? (WETH, token)
            : (token, WETH);

        p.pool = v3Factory.createPool(p.token0, p.token1, POOL_FEE);
        pool = p.pool;

        // Initialize pool price at the Band 1 floor (cheapest token price)
        IUniswapV3Pool(p.pool).initialize(
            p.wethIsToken0
                ? INIT_SQRT_PRICE_WETH_IS_TOKEN0
                : INIT_SQRT_PRICE_TOKEN_IS_TOKEN0
        );

        IERC20(token).approve(address(positionManager), tokenSupply);

        // Compute band amounts (60 / 25 / 15)
        uint256 b1 = (tokenSupply * BAND1_BPS) / 10000;
        uint256 b2 = (tokenSupply * BAND2_BPS) / 10000;
        uint256 b3 = tokenSupply - b1 - b2;

        // Mint 3 bands and collect token IDs
        uint256[3] memory ids;
        ids[0] = _mintBand(p, p.wethIsToken0 ? TICK_BOUND_1 : -TICK_BOUND_0, p.wethIsToken0 ? TICK_BOUND_0 : -TICK_BOUND_1, b1);
        ids[1] = _mintBand(p, p.wethIsToken0 ? TICK_BOUND_2 : -TICK_BOUND_1, p.wethIsToken0 ? TICK_BOUND_1 : -TICK_BOUND_2, b2);
        ids[2] = _mintBand(p, p.wethIsToken0 ? TICK_BOUND_3 : -TICK_BOUND_2, p.wethIsToken0 ? TICK_BOUND_2 : -TICK_BOUND_3, b3);

        IMindstateVault(vault).registerPositions(token, ids, creator, p.pool);
    }

    /// @dev Mint a single concentrated liquidity band and transfer the NFT to the vault.
    function _mintBand(
        SeedParams memory p,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmount
    ) internal returns (uint256 tokenId) {
        (tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: p.token0,
                token1: p.token1,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: p.wethIsToken0 ? 0 : tokenAmount,
                amount1Desired: p.wethIsToken0 ? tokenAmount : 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        positionManager.safeTransferFrom(address(this), vault, tokenId);
    }

    // ============ ERC721 Receiver (needed to receive NFT before forwarding to vault) ============

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ============ View Functions ============

    /// @notice Get launch data for a token
    function getLaunch(address token) external view returns (Launch memory) {
        return launches[token];
    }

    /// @notice Get total number of launches
    function getLaunchCount() external view returns (uint256) {
        return allLaunches.length;
    }

    /// @notice Get launches paginated
    function getLaunches(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = allLaunches.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allLaunches[i];
        }
        return result;
    }

    /// @notice Get all tokens launched by a specific creator
    function getCreatorTokens(address creator) external view returns (address[] memory) {
        return _creatorTokens[creator];
    }

    /// @notice Get number of tokens launched by a creator
    function getCreatorTokenCount(address creator) external view returns (uint256) {
        return _creatorTokens[creator].length;
    }

    /// @notice Get the V3 pool address for a launched token
    function getPool(address token) external view returns (address) {
        return launches[token].pool;
    }
}
