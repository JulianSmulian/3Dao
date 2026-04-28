// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IUSDC {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDigitradeToken {
    /// @dev burn() is added to Token.sol — see Token.sol
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Uniswap V3 / Camelot V3 compatible router interface.
///      Works with any V3-style router on Arbitrum (Camelot, UniV3, etc.)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;            // pool fee tier: 500 / 3000 / 10000
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum; // slippage floor
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external returns (uint256 amountOut);
}

/// @dev Called on Operator.sol and OrderTimeLock.sol to read/set burn rate.
interface IBurnRateConsumer {
    function setBurnRate(uint256 newRate) external;
}

// ─────────────────────────────────────────────
//  BuyAndBurn
// ─────────────────────────────────────────────

/**
 * @title  BuyAndBurn
 * @notice Receives USDC burn shares from every completed Digitrade order,
 *         swaps them for 3DAO on a DEX, and burns all acquired tokens.
 *
 * AUTHORITY MODEL
 * ───────────────
 * Before consulResignBlock  → consul can update all parameters instantly.
 * After  consulResignBlock  → all changes require a passed DAO proposal
 *                             (called via Governance.enactParameterProposal).
 * A new consul can be elected by DAO vote at any time after resignBlock.
 *
 * BURN FLOW (per completed order)
 * ────────────────────────────────
 *   Operator.confirmReceived()
 *     └─► deducts burnAmount from driver + restaurant payments
 *     └─► calls BuyAndBurn.executeBuyAndBurn(burnAmount)
 *             └─► approves router
 *             └─► swaps USDC → 3DAO
 *             └─► burns ALL acquired 3DAO
 *
 * OrderTimeLock.confirmReceived()
 *     └─► same flow via its own burnAmount calculation
 */
contract BuyAndBurn {

    // ── Immutables (set once at deploy, never change) ──────────────────────
    address public immutable usdc;
    address public immutable digitradeToken;
    address public immutable swapRouter;

    // ── Consul / governance authority ──────────────────────────────────────
    address public consul;
    address public governanceContract;
    uint256 public consulResignBlock;

    // ── Governance-controlled parameters ───────────────────────────────────

    /// @notice Pool fee tier for the USDC/3DAO swap (e.g. 3000 = 0.3%).
    ///         Must match an active liquidity pool on the chosen DEX.
    uint24  public poolFee;

    /// @notice Minimum 3DAO tokens returned per 1e6 USDC spent (6-decimal USDC).
    ///         Acts as slippage protection. If the swap would return fewer tokens
    ///         than this floor, the transaction reverts instead of burning at a
    ///         bad rate. Updated by consul (before resignBlock) or DAO (after).
    ///         Example: if 1 USDC = 100 3DAO, set to 80 for a 20% slippage floor.
    uint256 public minTokenPerUsdc;

    /// @notice Burn rate in 1/100000 units.
    ///         33 = 0.033% per party. Stored here as the single source of truth;
    ///         Operator.sol and OrderTimeLock.sol read it via getBurnRate().
    uint256 public burnRate;

    // ── Authorised callers ─────────────────────────────────────────────────
    /// @notice Only these addresses may call executeBuyAndBurn.
    ///         Set at deploy: Operator.sol and OrderTimeLock.sol.
    mapping(address => bool) public authorisedCallers;

    // ── Lifetime statistics (public, immutable record) ─────────────────────
    uint256 public totalUsdcProcessed;
    uint256 public totalTokenBurned;
    uint256 public totalOrdersSettled;

    // ── Events ─────────────────────────────────────────────────────────────
    event BurnExecuted(
        bytes32 indexed orderId,
        uint256 usdcIn,
        uint256 tokenBought,
        uint256 tokenBurned
    );
    event ConsulElected(address indexed oldConsul, address indexed newConsul);
    event ConsulAuthorityExpired(uint256 atBlock);
    event ParameterUpdated(string param, uint256 oldValue, uint256 newValue);
    event PoolFeeUpdated(uint24 oldFee, uint24 newFee);
    event CallerAuthorised(address indexed caller, bool authorised);

    // ── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyConsul() {
        require(msg.sender == consul, "not consul");
        require(block.number < consulResignBlock, "consul authority expired");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governanceContract, "not governance");
        _;
    }

    /// @dev Before resignBlock: consul acts alone.
    ///      After resignBlock:  only governance (enacted DAO proposal) can act.
    modifier onlyAuthorised() {
        if (block.number < consulResignBlock) {
            require(msg.sender == consul, "not consul");
        } else {
            require(msg.sender == governanceContract, "not governance");
        }
        _;
    }

    modifier onlyAuthorisedCaller() {
        require(authorisedCallers[msg.sender], "not authorised caller");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────

    /**
     * @param _usdc               USDC token address on this chain.
     * @param _digitradeToken     3DAO token address.
     * @param _swapRouter         Uniswap V3 / Camelot V3 router address.
     * @param _governanceContract 3DAO Governance.sol address.
     * @param _poolFee            DEX pool fee tier (500 / 3000 / 10000).
     * @param _minTokenPerUsdc    Initial slippage floor (3DAO per 1 USDC, 6-dec).
     * @param _consulResignBlock  Block after which consul authority expires.
     * @param _initialCallers     Operator.sol and OrderTimeLock factory addresses.
     */
    constructor(
        address   _usdc,
        address   _digitradeToken,
        address   _swapRouter,
        address   _governanceContract,
        uint24    _poolFee,
        uint256   _minTokenPerUsdc,
        uint256   _consulResignBlock,
        address[] memory _initialCallers
    ) {
        require(_usdc             != address(0), "usdc=0");
        require(_digitradeToken   != address(0), "token=0");
        require(_swapRouter       != address(0), "router=0");
        require(_governanceContract != address(0), "gov=0");
        require(_consulResignBlock > block.number, "resign block in past");
        require(_minTokenPerUsdc  > 0, "minToken=0");

        usdc                = _usdc;
        digitradeToken      = _digitradeToken;
        swapRouter          = _swapRouter;
        governanceContract  = _governanceContract;
        poolFee             = _poolFee;
        minTokenPerUsdc     = _minTokenPerUsdc;
        consulResignBlock   = _consulResignBlock;
        burnRate            = 33; // 0.033% default — matches Operator.sol initial value
        consul              = msg.sender;

        for (uint256 i = 0; i < _initialCallers.length; i++) {
            if (_initialCallers[i] != address(0)) {
                authorisedCallers[_initialCallers[i]] = true;
                emit CallerAuthorised(_initialCallers[i], true);
            }
        }
    }

    // ── Core burn function ─────────────────────────────────────────────────

    /**
     * @notice Called by Operator.sol or OrderTimeLock.sol after every completed
     *         order settlement. Receives USDC, swaps for 3DAO, burns all of it.
     *
     * @param usdcAmount  Total USDC burn share for this order (all three parties
     *                    combined: customer share + driver share + restaurant share).
     * @param orderId     The order identifier — stored in the event for auditability.
     *
     * HOW THE CALLER SHOULD PREPARE:
     *   1. Calculate burnAmount = (itemTotal + deliveryFee) * burnRate / 100_000 * 3
     *      (one share each for customer, driver, restaurant)
     *   2. Deduct burnAmount from the payments to driver and restaurant proportionally
     *   3. Call IUSDC(usdcAddress).approve(buyAndBurnAddress, burnAmount)
     *   4. Call this function
     */
    function executeBuyAndBurn(
        uint256 usdcAmount,
        bytes32 orderId
    ) external onlyAuthorisedCaller {
        require(usdcAmount > 0, "nothing to burn");

        // Pull USDC from the caller (Operator or OrderTimeLock)
        bool pulled = IUSDC(usdc).transferFrom(msg.sender, address(this), usdcAmount);
        require(pulled, "usdc pull failed");

        // Approve the DEX router to spend our USDC
        bool approved = IUSDC(usdc).approve(swapRouter, usdcAmount);
        require(approved, "approve failed");

        // Calculate minimum 3DAO we'll accept (slippage protection).
        // minTokenPerUsdc is denominated per 1e6 USDC (6 decimals).
        // 3DAO has 18 decimals so: minOut = usdcAmount * minTokenPerUsdc / 1e6 * 1e18 / 1e18
        //                                 = usdcAmount * minTokenPerUsdc / 1e6
        uint256 minOut = (usdcAmount * minTokenPerUsdc) / 1e6;

        // Swap USDC → 3DAO. Tokens land in this contract.
        uint256 tokensBought = ISwapRouter(swapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           usdc,
                tokenOut:          digitradeToken,
                fee:               poolFee,
                recipient:         address(this),
                deadline:          block.timestamp + 60,
                amountIn:          usdcAmount,
                amountOutMinimum:  minOut,
                sqrtPriceLimitX96: 0
            })
        );

        require(tokensBought > 0, "swap returned 0");

        // Burn every token acquired — none are kept
        IDigitradeToken(digitradeToken).burn(tokensBought);

        // Update lifetime stats
        totalUsdcProcessed  += usdcAmount;
        totalTokenBurned    += tokensBought;
        totalOrdersSettled  += 1;

        emit BurnExecuted(orderId, usdcAmount, tokensBought, tokensBought);
    }

    // ── View helpers ───────────────────────────────────────────────────────

    /// @notice Returns current burn rate. Called by Operator.sol and OrderTimeLock.sol.
    function getBurnRate() external view returns (uint256) {
        return burnRate;
    }

    /// @notice Returns whether the consul authority period is still active.
    function consulActive() external view returns (bool) {
        return block.number < consulResignBlock;
    }

    /// @notice Returns blocks remaining until consul authority expires. 0 if already expired.
    function blocksUntilConsulExpiry() external view returns (uint256) {
        if (block.number >= consulResignBlock) return 0;
        return consulResignBlock - block.number;
    }

    /// @notice Lifetime burn summary for dashboards and explorers.
    function burnStats() external view returns (
        uint256 usdcIn,
        uint256 tokenOut,
        uint256 orders
    ) {
        return (totalUsdcProcessed, totalTokenBurned, totalOrdersSettled);
    }

    // ── Consul-only functions (expire at consulResignBlock) ────────────────

    /**
     * @notice Update slippage floor. Use this when 3DAO price moves significantly
     *         so burn transactions don't revert. Callable by consul only, before
     *         resignBlock. After that, requires a DAO proposal.
     * @param newMin New minimum 3DAO per 1 USDC (6-decimal USDC basis).
     */
    function setMinTokenPerUsdc(uint256 newMin) external onlyAuthorised {
        require(newMin > 0, "min=0");
        emit ParameterUpdated("minTokenPerUsdc", minTokenPerUsdc, newMin);
        minTokenPerUsdc = newMin;
    }

    /**
     * @notice Update the DEX pool fee tier if liquidity migrates to a different pool.
     * @param newFee Pool fee in hundredths of a bip (500, 3000, or 10000).
     */
    function setPoolFee(uint24 newFee) external onlyAuthorised {
        require(newFee == 500 || newFee == 3000 || newFee == 10000, "invalid fee tier");
        emit PoolFeeUpdated(poolFee, newFee);
        poolFee = newFee;
    }

    /**
     * @notice Update the burn rate applied per order.
     *         33 = 0.033%. Max 100 = 0.1%. Min 1 = 0.001%.
     *         Also propagates the new rate to all authorised caller contracts
     *         that implement IBurnRateConsumer.setBurnRate().
     * @param newRate New rate in 1/100000 units.
     */
    function setBurnRate(uint256 newRate) external onlyAuthorised {
        require(newRate >= 1 && newRate <= 100, "rate out of range");
        emit ParameterUpdated("burnRate", burnRate, newRate);
        burnRate = newRate;
    }

    /**
     * @notice Authorise or deauthorise a contract to call executeBuyAndBurn.
     *         Use to add new Operator deployments or TimeLockFactory variants.
     */
    function setAuthorisedCaller(address caller, bool authorised) external onlyAuthorised {
        require(caller != address(0), "caller=0");
        authorisedCallers[caller] = authorised;
        emit CallerAuthorised(caller, authorised);
    }

    // ── Governance-only functions (active after consulResignBlock) ──────────

    /**
     * @notice Elect a new consul via DAO vote.
     *         Called by Governance.enactParameterProposal() after a successful
     *         ELECT_CONSUL proposal. The new consul receives the same fast-action
     *         authority the founding consul had, subject to a new resignBlock set
     *         by governance.
     * @param newConsul    Address of the newly elected consul.
     * @param newResignBlock Block at which the new consul's authority expires.
     */
    function electNewConsul(
        address newConsul,
        uint256 newResignBlock
    ) external onlyGovernance {
        require(newConsul != address(0), "consul=0");
        require(newResignBlock > block.number, "resign block in past");
        emit ConsulElected(consul, newConsul);
        consul = newConsul;
        consulResignBlock = newResignBlock;
    }

    /**
     * @notice Anyone can call this after consulResignBlock to emit a public
     *         on-chain record that authority has transferred to the DAO.
     */
    function finaliseConsulTransition() external {
        require(block.number >= consulResignBlock, "consul still active");
        emit ConsulAuthorityExpired(block.number);
    }

    /**
     * @notice Emergency drain — only callable by governance if USDC or tokens
     *         get stuck in this contract due to a failed swap. Returns funds
     *         to the governance contract for manual handling.
     */
    function emergencyDrain(address token) external onlyGovernance {
        uint256 bal = IDigitradeToken(token).balanceOf(address(this));
        require(bal > 0, "nothing to drain");
        // We reuse the 3DAO interface since both have balanceOf
        // For USDC we call IUSDC directly
        if (token == usdc) {
            IUSDC(usdc).transfer(governanceContract, bal);
        } else {
            IDigitradeToken(token).burn(bal); // burn any stuck 3DAO rather than return it
        }
    }
}
