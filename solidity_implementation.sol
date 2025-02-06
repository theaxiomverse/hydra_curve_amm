// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";


interface IHydraCurve {
    // Curve parameter struct
    struct CurveParams {
        uint256 initialPrice;
        uint256 initialSupply;
        uint256 maxSupply;
        uint256 baseWeight;
        uint256 priceMultiplier;
    }
    
    // Core price functions
    function calculatePrice(address token, uint256 supply) external view returns (uint256);
    function calculatePriceImpact(address token, uint256 amount, bool isBuy) external view returns (uint256);
    
    // Curve parameters
    function getCurveParams(address token) external view returns (CurveParams memory);
    
    // Curve initialization
    function initializeCurve(address token, CurveParams calldata params) external;
    
    // Price multiplier update
    function updatePriceMultiplier(address token, uint256 newMultiplier) external;
    
    // Events
    event CurveInitialized(
        address indexed token,
        uint256 initialPrice,
        uint256 initialSupply,
        uint256 maxSupply,
        uint256 baseWeight
    );
    
    event PriceUpdated(
        address indexed token,
        uint256 price,
        uint256 supply
    );
} 

/// @title HydraOpenZeppelin
/// @notice Ultra gas-optimized HYDRA curve implementation
abstract contract Curve is IHydraCurve {
    // Custom errors for gas savings
    error ExceedsMaxValue();
    error InvalidConfiguration();
    error MathOverflow();
    error ZeroValue();
    error InvalidBounds();
    error InvalidInput();

    error InvalidConfig();
    error PriceOutOfBounds();
    error ConfigNotInitialized();

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_PRICE_RATIO = 1000 * 1e18; // 1000x max price ratio
    uint256 private constant MIN_LIQUIDITY = 1e9;  // Minimum viable liquidity


    int256 private constant MIN_EXP = -41e18;
    int256 private constant MAX_EXP = 50e18;
    uint256 private constant MAX_STEEPNESS = 25;
    uint256 private constant MIN_STEEPNESS = 10;
    uint256 private constant DEGRADATION_THRESHOLD = 1e17;

    // Safety thresholds
    uint256 private constant MAX_RATIO_DEVIATION = 5e18; // 500% of target
    uint256 private constant SAFETY_MARGIN = 1e16; // 1% buffer

    // Monitoring events
    event ComponentCalculation(
        bytes32 indexed componentType,
        uint256 input,
        uint256 output,
        uint256 gasUsed,
        bool degraded
    );

    event LiquidityCalculation(
        uint256 indexed priceRatio,
        uint256 baseLiquidity,
        uint256 finalLiquidity,
        uint256 gasUsed,
        bool degraded,
        HydraMetrics metrics
    );

    event SafetyCheck(
        bytes32 indexed checkType,
        uint256 value,
        uint256 threshold,
        bool passed
    );

    // Enhanced monitoring metrics
    struct HydraMetrics {
        uint256 efficiencyRatio;
        uint256 priceDeviation;
        uint256 liquidityUtilization;
        bool usedFallback;
        uint64 timestamp;
    }

    // Memory struct for intermediate values
    struct CalcVars {
        uint256 baseValue;
        uint256 scaledValue;
        uint256 tempResult;
        bool degraded;
        uint256 gasStart;
    }

    // Packed config struct - single storage slot
    struct HydraConfig {
        uint32 sigmoidSteepness;
        uint64 sigmoidWeight;
        uint64 gaussianWidth;
        uint64 gaussianWeight;
        uint32 rationalPower;
        uint64 rationalWeight;
    }

    /// @notice Ultra-optimized sigmoid calculation
    /// @dev Uses assembly for maximum gas efficiency
   function calculateSigmoid(uint256 x, uint32 steepness) public pure returns (uint256) {
        if (x == 0) return PRECISION;
        if (steepness == 0) return PRECISION / 2;

        // New safe multiplication check
        uint256 product;
        unchecked {
            // Use assembly for safe overflow detection
            assembly {
                let mm := mulmod(x, steepness, not(0))
                let prod := mul(x, steepness)
                if gt(mm, prod) { revert(0, 0) }
                product := prod
            }
        }

        int256 exp_in = -int256(product / PRECISION);
        
        // Boundary checks
        if (exp_in <= MIN_EXP) return PRECISION / 10;
        if (exp_in >= MAX_EXP) return PRECISION;

        uint256 expValue = exp(exp_in);
        
        // Safe division check
        if (expValue >= type(uint256).max - PRECISION) {
            return PRECISION / 10;
        }

        return (PRECISION * PRECISION) / (PRECISION + expValue);
    }

    function exp(int256 x) internal pure returns (uint256) {
        if (x <= MIN_EXP) return 0;
        if (x >= MAX_EXP) return type(uint128).max;

        bool isNegative = x < 0;
        if (isNegative) x = -x;
        uint256 absX = uint256(x);

        // Calculate with higher precision
        uint256 result = PRECISION;
        uint256 term = PRECISION;
        uint256 termCount = 1;
        
        while (term > 1e9 && termCount < 7) {  // Limit iterations for gas
            unchecked {
                term = (term * absX) / (PRECISION * termCount);
                result += term;
                termCount++;
            }
        }

        if (isNegative) {
            return (PRECISION * PRECISION) / result;
        }
        return result;
    }

    /// @notice Ultra-optimized gaussian calculation
    function calculateGaussian(
        uint256 x,
        uint64 width
    ) public pure returns (uint256) {
        if (x == 0) return PRECISION;
        if (width == 0) return 0;

        unchecked {
            // Early return for very large x values
            if (x > type(uint128).max) return 0;

            uint256 widthSquared = uint256(width) * uint256(width);
            if (widthSquared == 0) return 0;

            // Check for potential overflow in x * x
            if (x > type(uint256).max / x) return 0;

            uint256 xSquared = x * x;

            if (xSquared / widthSquared > type(uint256).max / PRECISION)
                return 0;

            uint256 squared = (xSquared * PRECISION) / widthSquared;
            if (squared > type(uint128).max) return 0;

            // Use our exp function, converting to appropriate type
            return exp(-int256(squared));
        }
    }

    // Assembly-optimized sqrt implementation
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        assembly {
            switch x
            case 0 {
                result := 0
            }
            default {
                result := x
                let z := add(div(x, 2), 1)

                // Loop until we find the square root
                for {

                } lt(z, result) {

                } {
                    result := z
                    z := div(add(div(x, z), z), 2)
                }
            }
        }
    }

    /// @notice Main liquidity calculation with comprehensive safety
  function calculateLiquidity(
        uint256 x,
        uint256 y,
        uint256 currentPrice,
        uint256 targetPrice,
        HydraConfig memory config
    ) public pure returns (uint256) {
        // Input validation
        if (x == 0 || y == 0 || currentPrice == 0 || targetPrice == 0) {
            revert InvalidInput();
        }

        // Check price boundaries
        if (currentPrice > MAX_PRICE_RATIO || targetPrice > MAX_PRICE_RATIO) {
            revert PriceOutOfBounds();
        }

        // Validate config
        if (!_validateConfig(config)) {
            revert InvalidConfig();
        }

        unchecked {
            // Safe multiplication check for baseLiquidity calculation
            if (x > type(uint256).max / y) {
                revert MathOverflow();
            }
            uint256 baseLiquidity = Math.sqrt(x * y);

            // Ensure minimum viable liquidity
            if (baseLiquidity < MIN_LIQUIDITY) {
                revert InvalidInput();
            }

            // Calculate price ratio and delta with overflow protection
            uint256 priceRatio;
            if (currentPrice <= type(uint256).max / PRECISION) {
                priceRatio = (currentPrice * PRECISION) / targetPrice;
            } else {
                priceRatio = (currentPrice / targetPrice) * PRECISION;
            }

            uint256 priceDelta = priceRatio >= PRECISION
                ? priceRatio - PRECISION
                : PRECISION - priceRatio;

            // Calculate components with validated inputs
            uint256 sigmoid = calculateSigmoid(
                priceDelta,
                config.sigmoidSteepness
            );

            uint256 gaussian = calculateGaussian(
                priceDelta,
                config.gaussianWidth
            );

            uint256 rational = calculateRational(
                priceDelta,
                config.rationalPower
            );

            // Safe multiplication and division for combined factor
            uint256 sigmoidComponent = (sigmoid * config.sigmoidWeight) / PRECISION;
            uint256 gaussianComponent = (gaussian * config.gaussianWeight) / PRECISION;
            uint256 rationalComponent = (rational * config.rationalWeight) / PRECISION;

            if (sigmoidComponent > type(uint256).max - gaussianComponent ||
                sigmoidComponent + gaussianComponent > type(uint256).max - rationalComponent) {
                revert MathOverflow();
            }

            uint256 combinedFactor = sigmoidComponent + gaussianComponent + rationalComponent;

            // Final liquidity calculation with overflow protection
            if (baseLiquidity > type(uint256).max / combinedFactor) {
                revert MathOverflow();
            }

            uint256 finalLiquidity = (baseLiquidity * combinedFactor) / PRECISION;

            // Return the minimum of finalLiquidity and baseLiquidity
            return finalLiquidity < baseLiquidity ? finalLiquidity : baseLiquidity;
        }
    }

     function _validateConfig(HydraConfig memory config) private pure returns (bool) {
        // Validate steepness bounds
        if (config.sigmoidSteepness < MIN_STEEPNESS || config.sigmoidSteepness > MAX_STEEPNESS) {
            return false;
        }

        // Validate gaussian width
        if (config.gaussianWidth < 1e16 || config.gaussianWidth > 3e17) {
            return false;
        }

        // Validate rational power
        if (config.rationalPower == 0 || config.rationalPower > 32) {
            return false;
        }

        // Validate weights sum to PRECISION
        uint256 totalWeight = uint256(config.sigmoidWeight) +
            uint256(config.gaussianWeight) +
            uint256(config.rationalWeight);
            
        if (totalWeight != PRECISION) {
            return false;
        }

        return true;
    }

    function calculateRational(
        uint256 x,
        uint32 power
    ) public pure returns (uint256) {
        if (x == 0) return PRECISION;
        if (power == 0) return PRECISION; // Return PRECISION instead of 0 for zero power

        if (x > 1e36) return 0;

        unchecked {
            // Prevent overflow in power operation
            if (power > 32) return 0;

            uint256 xPow = fastPow(x, power);
            if (xPow > type(uint256).max - PRECISION) return 0;

            uint256 denominator = PRECISION + xPow;
            if (denominator <= PRECISION) return 0;

            return (PRECISION * PRECISION) / denominator;
        }
    }

    // Optimized exponential function
    function fastExp(int256 x) internal pure returns (uint256) {
        if (x <= MIN_EXP) return 0;
        if (x >= MAX_EXP) return type(uint128).max;

        unchecked {
            bool isNegative = x < 0;
            if (isNegative) x = -x;

            uint256 z = uint256(x);
            uint256 result = PRECISION;
            uint256 term = PRECISION;

            // Unrolled loop for gas optimization
            term = ((term * z) / PRECISION) / 1;
            result += term;

            term = ((term * z) / PRECISION) / 2;
            result += term;

            term = ((term * z) / PRECISION) / 3;
            result += term;

            if (isNegative) {
                return (PRECISION * PRECISION) / result;
            }
            return result;
        }
    }

    // Optimized power function
    function fastPow(uint256 x, uint32 power) internal pure returns (uint256) {
        // Prevent overflow and unreasonable computational cost
        if (power > 32) revert MathOverflow();
        if (power == 0) return PRECISION;
        if (power == 1) return x;
        if (x == 0) return 0;

        unchecked {
            uint256 result = PRECISION;
            uint256 base = x;

            // Optimized binary exponentiation
            while (power > 0) {
                if (power & 1 == 1) {
                    if (result > type(uint256).max / base) revert MathOverflow();
                    result = (result * base) / PRECISION;
                }
                if (base > type(uint256).max / base) revert MathOverflow();
                base = (base * base) / PRECISION;
                power >>= 1;
            }

            return result;
        }
    }

    // Optimized config functions with constant values
    function stableConfig() external pure returns (HydraConfig memory) {
        return HydraConfig(18, 6e17, 15e16, 3e17, 3, 1e17);
    }

    function standardConfig() external pure returns (HydraConfig memory) {
        return HydraConfig(15, 5e17, 2e17, 3e17, 4, 2e17);
    }

    function volatileConfig() external pure returns (HydraConfig memory) {
        return HydraConfig(12, 4e17, 25e16, 4e17, 5, 2e17);
    }

    /// @notice Enhanced config validation
    function validateConfig(
        HydraConfig memory config
    ) internal pure returns (bool) {
        // Check steepness bounds
        if (
            config.sigmoidSteepness < MIN_STEEPNESS ||
            config.sigmoidSteepness > MAX_STEEPNESS
        ) return false;

        // Check gaussian width
        if (config.gaussianWidth < 1e16 || config.gaussianWidth > 3e17)
            return false;

        // Validate weights sum to PRECISION
        uint256 totalWeight = uint256(config.sigmoidWeight) +
            uint256(config.gaussianWeight) +
            uint256(config.rationalWeight);
        if (totalWeight != PRECISION) return false;

        // Check rational power
        if (config.rationalPower == 0 || config.rationalPower > 32)
            return false;

        return true;
    }

     /// @notice Calculate price based on the Hydra curve
    function calculatePrice(
        uint256 x,
        uint256 y,
        HydraConfig memory config
    ) public pure returns (uint256) {
        // Input validation
        if (x == 0 || y == 0) {
            revert InvalidInput();
        }

        // Validate config
        if (!_validateConfig(config)) {
            revert InvalidConfig();
        }

        // Calculate price ratio
        uint256 priceRatio = (x * PRECISION) / y;

        // Calculate components with validated inputs
        uint256 sigmoid = calculateSigmoid(priceRatio, config.sigmoidSteepness);
        uint256 gaussian = calculateGaussian(priceRatio, config.gaussianWidth);
        uint256 rational = calculateRational(priceRatio, config.rationalPower);

        // Safe multiplication and division for combined factor
        uint256 sigmoidComponent = (sigmoid * config.sigmoidWeight) / PRECISION;
        uint256 gaussianComponent = (gaussian * config.gaussianWeight) / PRECISION;
        uint256 rationalComponent = (rational * config.rationalWeight) / PRECISION;

        if (sigmoidComponent > type(uint256).max - gaussianComponent ||
            sigmoidComponent + gaussianComponent > type(uint256).max - rationalComponent) {
            revert MathOverflow();
        }

        uint256 combinedFactor = sigmoidComponent + gaussianComponent + rationalComponent;

        // Calculate final price
        uint256 finalPrice = (priceRatio * combinedFactor) / PRECISION;

        return finalPrice;
    }
}
