// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma abicoder v2;

import "./Include.sol";
import "./iZiSwap.sol";

contract BtcFun is Sets {
	using SafeERC20 for IERC20;

    bytes32 internal constant _feeRate_             = "feeRate";
    int24 internal constant _feeRate_5pct_          = 59918;       // = -log(0.05^2, 1.0001)
    uint internal constant _max_count_              = 500;

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

    function offerorN(IERC20 token) public view returns(uint) {  return offerors[token].length;  }

    bool private entered;

    modifier nonReentrant {
        require(!entered, "REENTRANT");
        entered = true;
        _;
        entered = false;
    }

	mapping (IERC20 => mapping (address => uint)) public refundedOf;

    modifier pauseable {
        require(Config.get("pause") == 0, "paused");
        _;
    }

    function pause(bool b) external  {
        require(isGovernor() || msg.sender == Config.getA("pauseAdmin"), "admin only");
        Config.set("pause", b ? 1 : 0);
    }

    //function _createToken(string memory name, uint8 decimals, uint totalSupply, IERC20 currency, uint amount, uint quota, uint start, uint expiry) internal returns(IERC20 token) {
    //    require(tokens[name] == IERC20(address(0)), "Token exists!");
    //    token = new ERC20(name, name, decimals, totalSupply);
    //    tokens[name] = token;
    //    currencies[token] = currency;
    //    amounts[token] = amount;
    //    quotas[token] = quota;
    //    starts[token] = start;
    //    expiries[token] = expiry;
    //    emit CreateToken(name, decimals, totalSupply, token, currency, amount, quota, start, expiry);
    //}
    //event CreateToken(string name, uint8 decimals, uint totalSupply, IERC20 indexed token, IERC20 indexed currency, uint amount, uint quota, uint start, uint expiry);
    //
    //function createToken_(string memory name, uint8 decimals, uint totalSupply, IERC20 currency, uint amount, uint quota, uint start, uint expiry, uint pre) external payable governance returns(IERC20 token) {
    //    token = _createToken(name, decimals, totalSupply, currency, amount, quota, start, expiry);
    //    FunPool.createPool(address(token), totalSupply / 2, address(currency), amount);
    //    if(pre > 0)
    //        _offer(token, pre);
    //}
    //
    //function createToken(string memory name, uint8 decimals, uint totalSupply, address currency, uint amount, uint quota, uint start, uint expiry, string memory txid, uint8[] memory v, bytes32[] memory r, bytes32[] memory s) external returns(IERC20 token) {
    //}

    function createPool(IERC20 token, IERC20 currency, uint amount, uint quota, uint start, uint expiry, uint pre) external payable nonReentrant pauseable {
        require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        uint totalSupply = token.totalSupply();
        require(totalSupply == ICappedERC20(address(token)).cap() && totalSupply == token.balanceOf(msg.sender), "not all token");
        token.transferFrom(msg.sender, address(this), totalSupply);
        string memory name = ERC20(address(token)).symbol();
        require(tokens[name] == IERC20(address(0)), "Token exists!");
        require(start < expiry && block.timestamp < expiry, "too early expiry");
        tokens[name] = token;
        currencies[token] = currency;
        amounts[token] = amount;
        starts[token] = start;
        expiries[token] = expiry;
        FunPool.createPool(address(token), totalSupply / 2, address(currency), amount);
        emit CreatePool(name, totalSupply, token, currency, amount, quota, start, expiry);
        if(pre > 0)
            _offer(token, pre);
        quotas[token] = quota;
    }
    event CreatePool(string indexed name, uint totalSupply, IERC20 indexed token, IERC20 indexed currency, uint amount, uint quota, uint start, uint expiry);

	function checkAmount(IERC20 token, uint amount) public view returns(uint) {
        uint quota = quotas[token];
        uint offered = offeredOf[token][msg.sender];
        if(quota > 0 && amount + offered > quota)
		    amount = quota > offered ? quota - offered : 0;
        if(amount + totalOffered[token] > amounts[token])
            amount = amounts[token] - totalOffered[token];
        return amount;
    }
    
    function offer(IERC20 token, uint amount, uint timestamp, uint8 v, bytes32 r, bytes32 s) public payable nonReentrant pauseable {
		require(timestamp <= block.timestamp && block.timestamp <= timestamp + 180, "Signature expires");
        require(Config.getA("signatory") == ecrecover(keccak256(abi.encode(FunPool.chainId(), token, msg.sender, offeredOf[token][msg.sender], amount, timestamp)), v, r, s), "invalid signature");
        _offer(token, amount);
    }

	function _offer(IERC20 token, uint amount) internal {
        require(address(token) != address(0), "invalid token");
        IERC20 currency = currencies[token];
		require(block.timestamp >= starts[token], "it's not time yet");
		require(block.timestamp <= expiries[token], "expired");
        amount = checkAmount(token, amount);
		require(amount > 0, "no quota");
		//require(offeredOf[token][msg.sender] == 0, "offered already");
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
		emit Offer(token, msg.sender, amount, offeredOf[token][msg.sender], totalOffered[token]);
        if(totalOffered[token] >= amounts[token])
            emit Completed(token, currency, totalOffered[token]);
	}
	event Offer(IERC20 indexed token, address indexed addr, uint amount, uint offered, uint total);
    event Completed(IERC20 indexed token, IERC20 indexed currency, uint totalOffered);

    function airdropAccount(IERC20 token, address sender) external nonReentrant pauseable {
        return _claim(token, sender);
    }
    function _claim(IERC20 token, address sender) internal {
        require(totalOffered[token] == amounts[token], block.timestamp <= expiries[token] ? "offer unfinished" : "offer failed, call refund instead");
        if(token.balanceOf(address(this)) == token.totalSupply())
            tokenIds[token] = FunPool.addPool(address(token), token.totalSupply()/2, address(currencies[token]), amounts[token], int24(int(Config.get(_feeRate_))), Config.getA("feeTo"));
        require(offeredOf[token][sender] >  0, "not offered");
        require(claimedOf[token][sender] == 0, "claimed already");
        uint volume = offeredOf[token][sender] * IERC20(token).totalSupply() / 2 / amounts[token];
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
    event Refund(IERC20 indexed token, address indexed addr, uint refunded, IERC20 indexed currency);

    function collect(IERC20 token) external nonReentrant pauseable {
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

    function unlock(IERC20 token) external nonReentrant pauseable {
        uint tokenId = tokenIds[token];
        ILocker(FunPool.locker()).withdraw(tokenId);
        ILiquidityManager(FunPool.liquidityManager()).transferFrom(address(this), Config.getA("swapFeeTo"), tokenId);
    }
    
}
