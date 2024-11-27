// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma abicoder v2;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Include.sol";
import "./iZiSwap.sol";

contract BtcFun is Initializable, Sets {
	using SafeERC20 for IERC20;
    string public constant version = "1.0.0";

    bytes32 internal constant _feeRate_             = "feeRate";
    uint internal constant _max_count_              = 130;

    mapping (string => IERC20) public tokens;
    mapping (IERC20 => IERC20) public currencies;
    mapping (IERC20 => uint) public amounts;
    mapping (IERC20 => uint) public quotas;
    mapping (IERC20 => uint) public starts;
    mapping (IERC20 => uint) public expiries;
    mapping (IERC20 => uint) public totalOffered;
	mapping (IERC20 => mapping (address => uint)) public offeredOf;
	mapping (IERC20 => mapping (address => uint)) public claimedOf;
    mapping (IERC20 => uint) public tokenIds;
    mapping (IERC20 => address[]) public offerors;
    mapping (IERC20 => uint) public feeRate;

    function offerorN(IERC20 token) public view returns(uint) {  return offerors[token].length;  }

    bool private entered;

    modifier nonReentrant {
        require(!entered, "REENTRANT");
        entered = true;
        _;
        entered = false;
    }

	mapping (IERC20 => mapping (address => uint)) public refundedOf;
	mapping (IERC20 => uint) public supplies;

    modifier pauseable {
        require(Config.get("pause") == 0, "paused");
        _;
    }

    function pause() external {
        require(isGovernor() || msg.sender == Config.getA("pauseAdmin"), "admin only");
        Config.set("pause", 1);
        emit Pause();
    }
    event Pause();

    function unpause() external governance {
        Config.set("pause", 0);
        emit Unpause();
    }
    event Unpause();

    function initialize(address governor) external virtual initializer {
        initSetable(governor);
    }

    function createPool(IERC20 token, uint supply, IERC20 currency, uint amount, uint quota, uint start, uint expiry, uint pre) external payable nonReentrant pauseable {
        require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        address pool = address(0);
        uint _feeRate = uint(Config.get(_feeRate_));
        if(supply == token.totalSupply() && supply == ICappedERC20(address(token)).cap())
            pool = FunPool.createPool(address(token), supply / 2, address(currency), amount-getFeeRateAmount(amount, _feeRate));
        else
            require(isGovernor(), "partial token pool can only be created by governor");
        token.safeTransferFrom(msg.sender, address(this), supply);
        string memory name = ERC20(address(token)).symbol();
        require(tokens[name] == IERC20(address(0)), "Token exists!");
        require(start < expiry && block.timestamp < expiry, "too early expiry");
        tokens[name] = token;
        supplies[token] = supply;
        currencies[token] = currency;
        amounts[token] = amount;
        starts[token] = start;
        expiries[token] = expiry;
        feeRate[token] = _feeRate;
        emit CreatePool(name, supply, token, currency, amount, quota, start, expiry, pool);
        if(pre > 0)
            _offer(token, pre);
        quotas[token] = quota;
    }
    event CreatePool(string name, uint supply, IERC20 indexed token, IERC20 indexed currency, uint amount, uint quota, uint start, uint expiry, address indexed pool);

	function checkAmount(IERC20 token, uint amount) public view returns(uint) {
        uint quota = quotas[token];
        uint offered = offeredOf[token][msg.sender];
        if(quota > 0 && amount + offered > quota)
		    amount = quota > offered ? quota - offered : 0;
        if(amount + totalOffered[token] > amounts[token])
            amount = amounts[token] - totalOffered[token];
        return amount;
    }
    
    function offer(IERC20 token, uint amount, uint expiry, uint8 v, bytes32 r, bytes32 s) public payable nonReentrant pauseable {
		require(expiry >= block.timestamp, "Signature expires");
        require(Config.getA("signatory") == ecrecover(keccak256(abi.encode(FunPool.chainId(), token, msg.sender, offeredOf[token][msg.sender], amount, expiry)), v, r, s) && uint(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "invalid signature");
        _offer(token, amount);
    }

	function _offer(IERC20 token, uint amount) internal {
        require(amounts[token] > 0, "invalid token");
        IERC20 currency = currencies[token];
		require(block.timestamp >= starts[token], "it's not time yet");
		require(block.timestamp <= expiries[token], "expired");
        amount = checkAmount(token, amount);
		require(amount > 0, "no quota");
        if(offeredOf[token][msg.sender] == 0)
            offerors[token].push(msg.sender);
		offeredOf[token][msg.sender] += amount;
		totalOffered[token] += amount;

		if(address(currency) == address(0)) {
            require(msg.value >= amount, "value not enough");
            if(msg.value > amount)
                Address.sendValue(payable(msg.sender), msg.value - amount);
        } else {
            require(currency.allowance(msg.sender, address(this)) >= amount, "allowance not enough");
            require(currency.balanceOf(msg.sender) >= amount, "balance not enough");
            currency.safeTransferFrom(msg.sender, address(this), amount);
        }
		uint total = totalOffered[token];
        emit Offer(token, msg.sender, amount, offeredOf[token][msg.sender], total);
        if(total >= amounts[token]) {
            emit Completed(token, currency, total);
            if(supplies[token] == token.totalSupply()){
                uint feeRateAmount = getFeeRateAmount(total, feeRate[token]);
                IERC20(currency).safeTransfer(Config.getA("feeTo"), feeRateAmount);
                tokenIds[token] = FunPool.addPool(address(token), supplies[token]/2, address(currency), amount - feeRateAmount);
            }
            else if(address(currency) == address(0))
                Address.sendValue(payable(Config.getA(_governor_)), total);
            else
                currency.safeTransfer(Config.getA(_governor_), total);
        }
    }
	event Offer(IERC20 indexed token, address indexed sender, uint amount, uint offered, uint total);
    event Completed(IERC20 indexed token, IERC20 indexed currency, uint totalOffered);

    function getFeeRateAmount(uint amount, uint _feeRate) internal pure returns(uint) {
        return amount * _feeRate / 1e18;
    }

    function airdropAccount(IERC20 token, address sender) external nonReentrant pauseable {
        return _claim(token, sender);
    }
    function _claim(IERC20 token, address sender) internal {
        require(totalOffered[token] == amounts[token], block.timestamp <= expiries[token] ? "offer unfinished" : "offer failed, call refund instead");
        require(offeredOf[token][sender] >  0, "not offered");
        require(claimedOf[token][sender] == 0, "claimed already");
        uint supply = supplies[token];
        if(supply == token.totalSupply())
            supply /= 2;
        uint volume = offeredOf[token][sender] * supply / amounts[token];
        claimedOf[token][sender] = volume;
        token.safeTransfer(sender, volume);
        emit Claim(msg.sender, token, sender, volume, currencies[token], offeredOf[token][sender]);
    }
    event Claim(address sender, IERC20 indexed token, address indexed to, uint volume, IERC20 indexed currency, uint offered);
    
    function airdrop(IERC20 token, uint offset, uint count) external nonReentrant pauseable {
        require(count <= _max_count_, "too many count");
        uint N = Math.min(offset + count, offerorN(token));
        for(uint i = offset; i < N; i++) {
            address to = offerors[token][i];
            if(claimedOf[token][to] == 0)
                _claim(token, to);
        }
    }
    
    function refund(IERC20 token, uint offset, uint count) external nonReentrant pauseable {
        require(count <= _max_count_, "too many count");
        uint N = Math.min(offset + count, offerorN(token));
        for(uint i = offset; i < N; i++) {
            address to = offerors[token][i];
            if(offeredOf[token][to] > 0)
                _refund(token, to);
        }
    }
    
    function refundAccount(IERC20 token, address sender) external nonReentrant pauseable {
        return _refund(token, sender);
    }
    function _refund(IERC20 token, address sender) internal {
        require(block.timestamp > expiries[token], "not expired yet");
        require(totalOffered[token] < amounts[token], "offer finished, call claim instead");
        uint offered  = offeredOf [token][sender];
        uint refunded = refundedOf[token][sender];
        require(offered > 0 && refunded == 0, "not offered or refund already");
        uint fee = offered * Config.get("refundFeeRate") / 1e18;
        refunded = offered - fee;
        refundedOf[token][sender] = refunded;
        address feeTo = Config.getA("feeTo");
		IERC20 currency = currencies[token];
        if(address(currency) == address(0)) {
            Address.sendValue(payable(feeTo), fee);
            Address.sendValue(payable(sender), refunded);
        } else {
            currency.safeTransfer(feeTo, fee);
            currency.safeTransfer(sender, refunded);
        }
        emit Refund(token, sender, refunded, currency);
    }
    event Refund(IERC20 indexed token, address indexed sender, uint refunded, IERC20 indexed currency);

    function collect(IERC20 token) external nonReentrant {
        require(address(token) != address(0), "invalid token");
        IERC20 currency = currencies[token];
        if(address(currency) == address(0))
            currency = IERC20(ILiquidityManager(FunPool.liquidityManager()).WETH9());
        uint amount = currency.balanceOf(address(this));
        uint volume = token.balanceOf(address(this));
        ILocker(FunPool.locker()).collect(tokenIds[token]);
        address swapFeeTo = Config.getA("swapFeeTo");
        currency.safeTransfer(swapFeeTo, currency.balanceOf(address(this)) - amount);
        token.safeTransfer(swapFeeTo, token.balanceOf(address(this)) - volume);
    }

    function unlock(IERC20 token) external nonReentrant governance {
        uint tokenId = tokenIds[token];
        ILocker(FunPool.locker()).withdraw(tokenId);
        ILiquidityManager(FunPool.liquidityManager()).transferFrom(address(this), Config.getA(_governor_), tokenId);
    }
    
}
