// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "./Include.sol";

library FunPool {
	using SafeERC20 for IERC20;

    uint24 internal constant _fee_              = 10000;     // 1.00%

    function createPool(address token, uint volume, address currency, uint amount) internal returns (address pool) {
        ILiquidityManager lm = ILiquidityManager(liquidityManager());
        if(currency == address(0))
            currency = lm.WETH9();
        (address token0, address token1) = token <= currency ? (token, currency) : (currency, token);
        uint price = token <= currency ? amount * 2**96 / volume : volume * 2**96 / amount;
        uint160 sqrtPrice_96 = SafeCast.toUint160(Math.sqrt(price * 2**96));
        (int24 floor, int24 upper) = LogPowMath.getLogSqrtPriceFU(sqrtPrice_96);
        int24 initialPoint = token <= currency ? floor : upper;
        pool = IiZiSwapFactory(lm.factory()).pool(token0, token1, _fee_);
        require(pool == address(0), "pool exist");
        pool = lm.createPool(token0, token1, _fee_, initialPoint);
    }

    function addPool(address token, uint volume, address currency, uint amount, int24 feeRate, address feeTo) internal returns (uint tokenId){
        ILiquidityManager lm = ILiquidityManager(liquidityManager());
        if(currency == address(0)) {
            currency = lm.WETH9();
            IWETH(currency).deposit{value: amount}();
        }
        IERC20(token).approve(address(lm), volume);
        IERC20(currency).approve(address(lm), amount);
        (int24 pl, int24 pr) = calcRange(token, currency, feeRate);
        uint amountLP;   
        if(token <= currency)
            (tokenId, , , amountLP) = lm.mint(ILiquidityManager.MintParam({
                miner           : address(this),
                tokenX          : token,
                tokenY          : currency,
                fee             : _fee_,
                pl              : pl,
                pr              : pr,
                xLim            : uint128(volume),
                yLim            : uint128(amount),
                amountXMin      : 0,
                amountYMin      : 0,
                deadline        : block.timestamp
            }));
        else
            (tokenId, , amountLP, ) = lm.mint(ILiquidityManager.MintParam({
                miner           : address(this),
                tokenX          : currency,
                tokenY          : token,
                fee             : _fee_,
                pl              : pl,
                pr              : pr,
                xLim            : uint128(amount),
                yLim            : uint128(volume),
                amountXMin      : 0,
                amountYMin      : 0,
                deadline        : block.timestamp
            }));
        if(feeRate != 0)
            IERC20(currency).safeTransfer(feeTo, amount - amountLP);
        lm.approve(locker(), tokenId);
        ILocker(locker()).lock(tokenId, 180 days);
    }

    function calcRange(address token, address currency, int24 rate) view internal returns (int24 pl, int24 pr) {
        (address token0, address token1) = token <= currency ? (token, currency) : (currency, token);
        if(token <= currency)
            rate = -rate;
        IiZiSwapPool pool = IiZiSwapPool(IiZiSwapFactory(ILiquidityManager(liquidityManager()).factory()).pool(token0, token1, _fee_));
        int24 leftMostPt  = pool.leftMostPt();
        int24 rightMostPt = pool.rightMostPt();
        int24 pointDelta  = pool.pointDelta();
        (,int24 currentPoint,,,,,,) = pool.state();
        pr = MaxMinMath.min(rightMostPt, currentPoint + rightMostPt / 2) / pointDelta * pointDelta;
        pl = MaxMinMath.max(leftMostPt, currentPoint * 2 - pr) / pointDelta * pointDelta;
        if(rate < 0)
            pl = MaxMinMath.max(pl, currentPoint + rate) / pointDelta * pointDelta;
        else if(rate > 0)
            pr = MaxMinMath.min(pr, currentPoint + rate) / pointDelta * pointDelta;
    }

    function liquidityManager() internal view returns (address) {
        uint chainid = chainId();
        if(chainid == 4200)         // Merlin
            return 0x261507940678Bf22d8ee96c31dF4a642294c0467;
        else if(chainid == 686868)  // Merlin Testnet
            return 0xC6C7c2edF70A3245ad6051E93809162B9758ce08;
        else if(chainid == 97)      // BNB Chain Testnet
            return 0xDE02C26c46AC441951951C97c8462cD85b3A124c;
        else
            revert("err chain");
    }

    function locker() internal view returns (address) {
        uint chainid = chainId();
        if(chainid == 4200)         // Merlin Mainnet
            return 0xf9bEdf5D2D0A1Dba811C0eFe11d6bE489e2572Db;
        else if(chainid == 686868)  // Merlin Testnet
            return 0x0386F23662153960B0506025b950dB0e5D2A8367;
        else if(chainid == 97)      // BNB Chain Testnet
            return 0x99c5cA53dBf69E8E35b384dB9f5848959737ebBb;
        else
            revert("err chain");
    }

    function bridged() internal view returns (IBridged) {
        uint chainid = chainId();
        if(chainid == 4200)         // Merlin Mainnet
            return IBridged(0xa212d68499947960cd3A24861E788E7C38c0fb9D);
        else if(chainid == 686868)  // Merlin Testnet
            return IBridged(0x53750303Ca54905e6fb6161ebc70AF61C9000C69);
        else
            revert("err chain");
    }

    function chainId() internal view returns (uint id) {
        assembly { id := chainid() }
    }
}    


interface IBridged {
    function erc20TokenInfoSupported(IERC20 token) external view returns(bool);
}

interface ICappedERC20 is IERC20 {
    function cap() external view returns(uint);
}

interface IWETH {
    function deposit() external payable;
}

interface IiZiSwapPool {
    function leftMostPt() external view returns (int24);
    function rightMostPt() external view returns (int24);
    function pointDelta() external view returns (int24);
    function state() external view returns (
            uint160 sqrtPrice_96,
            int24 currentPoint,
            uint16 observationCurrentIndex,
            uint16 observationQueueLen,
            uint16 observationNextQueueLen,
            bool locked,
            uint128 liquidity,
            uint128 liquidityX
        );
}

interface IiZiSwapFactory {
    function pool(
        address tokenX,
        address tokenY,
        uint24 fee
    ) external view returns(address);

}

interface ILiquidityManager {
    struct MintParam {
        // miner address
        address miner;
        // tokenX of swap pool
        address tokenX;
        // tokenY of swap pool
        address tokenY;
        // fee amount of swap pool
        uint24 fee;
        // left point of added liquidity
        int24 pl;
        // right point of added liquidity
        int24 pr;
        // amount limit of tokenX miner willing to deposit
        uint128 xLim;
        // amount limit tokenY miner willing to deposit
        uint128 yLim;
        // minimum amount of tokenX miner willing to deposit
        uint128 amountXMin;
        // minimum amount of tokenY miner willing to deposit
        uint128 amountYMin;

        uint256 deadline;
    }
    /// @notice Add a new liquidity and generate a nft.
    /// @param mintParam params, see MintParam for more
    /// @return lid id of nft
    /// @return liquidity amount of liquidity added
    /// @return amountX amount of tokenX deposited
    /// @return amountY amount of tokenY depsoited
    function mint(MintParam calldata mintParam) external payable returns(
        uint256 lid,
        uint128 liquidity,
        uint256 amountX,
        uint256 amountY
    );

    function WETH9() view external returns (address);
    function factory() view external returns (address);
    function createPool(address tokenX, address tokenY, uint24 fee, int24 initialPoint) external returns (address);
    
    function approve(address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint tokenId) external;
}

interface ILocker {
    function lock(uint256 tokenId, uint256 lockTime) external;
    function withdraw(uint256 tokenId) external;
    function collect(uint256 tokenId) external;
}

library MaxMinMath {
    function max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    function min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }
}

library LogPowMath {

    int24 internal constant MIN_POINT = -887272;

    int24 internal constant MAX_POINT = -MIN_POINT;

    uint160 internal constant MIN_SQRT_PRICE = 4295128739;

    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @notice sqrt(1.0001^point) in form oy 96-bit fix point num
    function getSqrtPrice(int24 point) internal pure returns (uint160 sqrtPrice_96) {
        uint256 absIdx = point < 0 ? uint256(-int256(point)) : uint256(int256(point));
        require(absIdx <= uint256(int256(MAX_POINT)), 'T');

        uint256 value = absIdx & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absIdx & 0x2 != 0) value = (value * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absIdx & 0x4 != 0) value = (value * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absIdx & 0x8 != 0) value = (value * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absIdx & 0x10 != 0) value = (value * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absIdx & 0x20 != 0) value = (value * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absIdx & 0x40 != 0) value = (value * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absIdx & 0x80 != 0) value = (value * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absIdx & 0x100 != 0) value = (value * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absIdx & 0x200 != 0) value = (value * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absIdx & 0x400 != 0) value = (value * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absIdx & 0x800 != 0) value = (value * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absIdx & 0x1000 != 0) value = (value * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absIdx & 0x2000 != 0) value = (value * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absIdx & 0x4000 != 0) value = (value * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absIdx & 0x8000 != 0) value = (value * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absIdx & 0x10000 != 0) value = (value * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absIdx & 0x20000 != 0) value = (value * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absIdx & 0x40000 != 0) value = (value * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absIdx & 0x80000 != 0) value = (value * 0x48a170391f7dc42444e8fa2) >> 128;

        if (point > 0) value = type(uint256).max / value;

        sqrtPrice_96 = uint160((value >> 32) + (value % (1 << 32) == 0 ? 0 : 1));
    }

    // floor(log1.0001(sqrtPrice_96))
    function getLogSqrtPriceFloor(uint160 sqrtPrice_96) internal pure returns (int24 logValue) {
        // second inequality must be < because the price can nevex reach the price at the max tick
        require(sqrtPrice_96 >= MIN_SQRT_PRICE && sqrtPrice_96 < MAX_SQRT_PRICE, 'R');
        uint256 sqrtPrice_128 = uint256(sqrtPrice_96) << 32;

        uint256 x = sqrtPrice_128;
        uint256 m = 0;

        assembly {
            let y := shl(7, gt(x, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(6, gt(x, 0xFFFFFFFFFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(5, gt(x, 0xFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(4, gt(x, 0xFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(3, gt(x, 0xFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(2, gt(x, 0xF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(1, gt(x, 0x3))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := gt(x, 0x1)
            m := or(m, y)
        }

        if (m >= 128) x = sqrtPrice_128 >> (m - 127);
        else x = sqrtPrice_128 << (127 - m);

        int256 l2 = (int256(m) - 128) << 64;

        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(63, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(62, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(61, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(60, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(59, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(58, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(57, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(56, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(55, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(54, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(53, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(52, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(51, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(50, y))
        }

        int256 ls10001 = l2 * 255738958999603826347141;

        int24 logFloor = int24((ls10001 - 3402992956809132418596140100660247210) >> 128);
        int24 logUpper = int24((ls10001 + 291339464771989622907027621153398088495) >> 128);

        logValue = logFloor == logUpper ? logFloor : getSqrtPrice(logUpper) <= sqrtPrice_96 ? logUpper : logFloor;
    }

    function getLogSqrtPriceFU(uint160 sqrtPrice_96) internal pure returns (int24 logFloor, int24 logUpper) {
        // second inequality must be < because the price can nevex reach the price at the max tick
        require(sqrtPrice_96 >= MIN_SQRT_PRICE && sqrtPrice_96 < MAX_SQRT_PRICE, 'R');
        uint256 sqrtPrice_128 = uint256(sqrtPrice_96) << 32;

        uint256 x = sqrtPrice_128;
        uint256 m = 0;

        assembly {
            let y := shl(7, gt(x, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(6, gt(x, 0xFFFFFFFFFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(5, gt(x, 0xFFFFFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(4, gt(x, 0xFFFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(3, gt(x, 0xFF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(2, gt(x, 0xF))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := shl(1, gt(x, 0x3))
            m := or(m, y)
            x := shr(y, x)
        }
        assembly {
            let y := gt(x, 0x1)
            m := or(m, y)
        }

        if (m >= 128) x = sqrtPrice_128 >> (m - 127);
        else x = sqrtPrice_128 << (127 - m);

        int256 l2 = (int256(m) - 128) << 64;

        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(63, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(62, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(61, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(60, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(59, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(58, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(57, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(56, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(55, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(54, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(53, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(52, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(51, y))
            x := shr(y, x)
        }
        assembly {
            x := shr(127, mul(x, x))
            let y := shr(128, x)
            l2 := or(l2, shl(50, y))
        }

        int256 ls10001 = l2 * 255738958999603826347141;

        logFloor = int24((ls10001 - 3402992956809132418596140100660247210) >> 128);
        logUpper = int24((ls10001 + 291339464771989622907027621153398088495) >> 128);
    }
    
}

