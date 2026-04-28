// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external returns (uint256 amountOut);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDigitradeToken {
    function burn(uint256 amount) external;
}

contract BuyAndBurn {
    address public immutable usdc;
    address public immutable digitradeToken;
    address public immutable swapRouter;      // Uniswap V3 / Camelot router
    address public immutable operatorContract;
    uint24  public immutable poolFee;         // e.g. 3000 = 0.3% pool fee tier

    // Slippage protection: minimum 3DAO received per USDC spent
    // Set conservatively — updated by governance if token price moves significantly
    uint256 public minTokenPerUsdc;

    uint256 public totalUsdcBurned;
    uint256 public totalTokenBurned;

    event BuyAndBurnExecuted(
        uint256 usdcIn,
        uint256 tokenBought,
        uint256 tokenBurned
    );

    modifier onlyOperator() {
        require(msg.sender == operatorContract, "not operator");
        _;
    }

    constructor(
        address _usdc,
        address _digitradeToken,
        address _swapRouter,
        address _operatorContract,
        uint24  _poolFee,
        uint256 _minTokenPerUsdc
    ) {
        usdc             = _usdc;
        digitradeToken   = _digitradeToken;
        swapRouter       = _swapRouter;
        operatorContract = _operatorContract;
        poolFee          = _poolFee;
        minTokenPerUsdc  = _minTokenPerUsdc;
    }

    /// @notice Called by Operator.sol after every completed order.
    /// @param usdcAmount  The burn share in USDC (0.033% × 3 parties combined).
    function executeBuyAndBurn(uint256 usdcAmount) external onlyOperator {
        require(usdcAmount > 0, "nothing to burn");

        // 1. Approve router to spend our USDC
        IERC20(usdc).approve(swapRouter, usdcAmount);

        // 2. Swap USDC → 3DAO on DEX
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           usdc,
                tokenOut:          digitradeToken,
                fee:               poolFee,
                recipient:         address(this),   // receive token here first
                deadline:          block.timestamp + 60,
                amountIn:          usdcAmount,
                amountOutMinimum:  (usdcAmount * minTokenPerUsdc) / 1e6,
                sqrtPriceLimitX96: 0
            });

        uint256 tokensBought = ISwapRouter(swapRouter).exactInputSingle(params);

        // 3. Burn ALL acquired tokens
        IDigitradeToken(digitradeToken).burn(tokensBought);

        totalUsdcBurned  += usdcAmount;
        totalTokenBurned += tokensBought;

        emit BuyAndBurnExecuted(usdcAmount, tokensBought, tokensBought);
    }

    /// @notice View total economic activity routed through burns.
    function burnStats() external view returns (uint256 usdcIn, uint256 tokenOut) {
        return (totalUsdcBurned, totalTokenBurned);
    }
}
