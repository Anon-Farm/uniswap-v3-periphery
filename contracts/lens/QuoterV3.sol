// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.15;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import '@uniswap/v3-core/contracts/libraries/Simulate.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

import '../interfaces/IQuoterV3.sol';
import '../base/PeripheryImmutableState.sol';
import '../libraries/Path.sol';
import '../libraries/PoolAddress.sol';
import '../libraries/CallbackValidation.sol';

/// @title Provides quotes for swaps
/// @notice Allows getting the expected amount out or amount in for a given swap without executing the swap
/// @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
/// the swap and check the amounts in the callback.
contract QuoterV3 is IQuoterV3, PeripheryImmutableState {
    using Path for bytes;
    using SafeCast for uint256;
    using Simulate for IUniswapV3Pool;

    constructor(address _factory, address _WETH9) PeripheryImmutableState(_factory, _WETH9) {}

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    function decodeFirstPool(bytes memory path, bool exactIn)
        private
        view
        returns (IUniswapV3Pool pool, bool zeroForOne)
    {
        (address tokenA, address tokenB, uint24 fee) = path.decodeFirstPool();
        pool = getPool(tokenA, tokenB, fee);
        zeroForOne = exactIn == (tokenA < tokenB);
    }

    /// @inheritdoc IQuoterV3
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) public view override returns (uint256 amountOut) {
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee).simulateSwap(
            zeroForOne,
            amountIn.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96
        );
        return zeroForOne ? uint256(-amount1) : uint256(-amount0);
    }

    /// @inheritdoc IQuoterV3
    function quoteExactInput(bytes memory path, uint256 amountIn) external view override returns (uint256 amountOut) {
        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            amountIn = quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                path = path.skipToken();
            } else {
                return amountIn;
            }
        }
    }

    /// @inheritdoc IQuoterV3
    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) public view override returns (uint256 amountIn) {
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee).simulateSwap(
            zeroForOne,
            -amountOut.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96
        );
        return zeroForOne ? uint256(amount0) : uint256(amount1);
    }

    /// @inheritdoc IQuoterV3
    function quoteExactOutput(bytes memory path, uint256 amountOut) external view override returns (uint256 amountIn) {
        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            (address tokenOut, address tokenIn, uint24 fee) = path.decodeFirstPool();

            // the inputs of prior swaps become the outputs of subsequent ones
            amountOut = quoteExactOutputSingle(tokenIn, tokenOut, fee, amountOut, 0);

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                path = path.skipToken();
            } else {
                return amountOut;
            }
        }
    }

    function quoteExactInputSingleV3(
        IUniswapV3Pool pool,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        Simulate.State memory swapState
    ) internal view returns (uint256 amountOut) {
        (int256 amount0, int256 amount1) = pool.simulateSwap(
            zeroForOne,
            amountIn.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            swapState
        );
        return zeroForOne ? uint256(-amount1) : uint256(-amount0);
    }

    function quoteExactInputV3(
        bytes memory path,
        uint256 amountIn,
        Simulate.State[] memory swapStates
    ) external view override returns (uint256[] memory amounts, Simulate.State[] memory swapStatesEnd) {
        uint256 i = path.numPools();
        amounts = new uint256[](i + 1);
        if (swapStates.length == 0) {
            swapStates = new Simulate.State[](i);
        }
        amounts[i] = amountIn;
        while (true) {
            (IUniswapV3Pool pool, bool zeroForOne) = decodeFirstPool(path, true);

            // the outputs of prior swaps become the inputs to subsequent ones
            --i;
            amounts[i] = quoteExactInputSingleV3(pool, zeroForOne, amounts[i + 1], 0, swapStates[i]);

            // decide whether to continue or terminate
            if (i > 0) {
                path = path.skipToken();
            } else {
                break;
            }
        }
        return (amounts, swapStates);
    }

    function quoteExactOutputSingleV3(
        IUniswapV3Pool pool,
        bool zeroForOne,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96,
        Simulate.State memory swapState
    ) internal view returns (uint256 amountIn) {
        (int256 amount0, int256 amount1) = pool.simulateSwap(
            zeroForOne,
            -amountOut.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            swapState
        );
        return zeroForOne ? uint256(amount0) : uint256(amount1);
    }

    function quoteExactOutputV3(
        bytes memory path,
        uint256 amountOut,
        Simulate.State[] memory swapStates
    ) external view override returns (uint256[] memory amounts, Simulate.State[] memory swapStatesEnd) {
        uint256 i = path.numPools();
        amounts = new uint256[](i + 1);
        if (swapStates.length == 0) {
            swapStates = new Simulate.State[](i);
        }
        amounts[i] = amountOut;
        while (true) {
            (IUniswapV3Pool pool, bool zeroForOne) = decodeFirstPool(path, false);

            // the inputs of prior swaps become the outputs of subsequent ones
            --i;
            amounts[i] = quoteExactOutputSingleV3(pool, zeroForOne, amounts[i + 1], 0, swapStates[i]);

            // decide whether to continue or terminate
            if (i > 0) {
                path = path.skipToken();
            } else {
                break;
            }
        }
        return (amounts, swapStates);
    }
}
