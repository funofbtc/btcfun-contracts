// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma abicoder v2;

import "./Include.sol";
import "./iZiSwap.sol";

contract BtcFun is Sets {
	using SafeERC20 for IERC20;

    bytes32 internal constant _feeRate_             = "feeRate";
    int24 internal constant _feeRate_5pct_          = 59918;       // = -log(0.05^2, 1.0001)

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

    function _createToken(string memory name, uint8 decimals, uint totalSupply, IERC20 currency, uint amount, uint quota, uint start, uint expiry) internal returns(IERC20 token) {
        require(tokens[name] == IERC20(address(0)), "Token exists!");
        token = new ERC20(name, name, decimals, totalSupply);
        tokens[name] = token;
        currencies[token] = currency;
        amounts[token] = amount;
        quotas[token] = quota;
        starts[token] = start;
        expiries[token] = expiry;
        emit CreateToken(name, decimals, totalSupply, token, currency, amount, quota, start, expiry);
    }
    event CreateToken(string name, uint8 decimals, uint totalSupply, IERC20 indexed token, IERC20 indexed currency, uint amount, uint quota, uint start, uint expiry);

    function createToken_(string memory name, uint8 decimals, uint totalSupply, IERC20 currency, uint amount, uint quota, uint start, uint expiry, uint pre) external payable governance returns(IERC20 token) {
        token = _createToken(name, decimals, totalSupply, currency, amount, quota, start, expiry);
        FunPool.createPool(address(token), totalSupply / 2, address(currency), amount);
        offer(token, pre);
    }

    //function createToken(string memory name, uint8 decimals, uint totalSupply, address currency, uint amount, uint quota, uint start, uint expiry, string memory txid, uint8[] memory v, bytes32[] memory r, bytes32[] memory s) external returns(IERC20 token) {
    //}

	function offer(IERC20 token, uint amount) public payable {
		IERC20 currency = currencies[token];
		require(block.timestamp >= starts[token], "it's not time yet");
		require(block.timestamp <= expiries[token], "expired");
        uint quota = quotas[token];
        uint offered = offeredOf[token][msg.sender];
        if(!isGovernor() && quota > 0 && amount + offered > quota)
		    amount = quota > offered ? quota - offered : 0;
        if(amount + totalOffered[token] > amounts[token])
            amount = amounts[token] - totalOffered[token];
		require(amount > 0, "no quota");
		//require(offeredOf[token][msg.sender] == 0, "offered already");
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
		emit Offer(token, msg.sender, amount, offered + amount, totalOffered[token]);
	}
	event Offer(IERC20 indexed token, address indexed addr, uint amount, uint offered, uint total);

    function claim(IERC20 token) external {
        require(totalOffered[token] == amounts[token], block.timestamp <= expiries[token] ? "offer unfinished" : "offer failed, call refund instead");
        if(token.balanceOf(address(this)) == token.totalSupply())
            tokenIds[token] = FunPool.addPool(address(token), token.totalSupply()/2, address(currencies[token]), amounts[token], int24(int(Config.get(_feeRate_))), Config.getA(_governor_));
        require(claimedOf[token][msg.sender] == 0, "claimed already"); 
        uint volume = offeredOf[token][msg.sender] * IERC20(token).totalSupply() / 2 / amounts[token];
        claimedOf[token][msg.sender] = volume;
        token.safeTransfer(msg.sender, volume);
        emit Claim(token, msg.sender, volume);
    }
    event Claim(IERC20 indexed token, address indexed addr, uint volume);
    
    function refund(IERC20 token) external {
        require(block.timestamp > expiries[token], "not expired yet");
        require(totalOffered[token] < amounts[token], "offer finished, call claim instead");
        uint amount = offeredOf[token][msg.sender];
        require(amount > 0, "not offered or refund already");
        offeredOf[token][msg.sender] = 0;
		IERC20 currency = currencies[token];
        if(address(currency) == address(0))
            Address.sendValue(payable(msg.sender), amount);
        else
            currency.safeTransfer(msg.sender, amount);
        emit Refund(token, msg.sender, amount);
    }
    event Refund(IERC20 indexed token, address indexed addr, uint amount);

    function collect(IERC20 token) external {
        IERC20 currency = currencies[token];
        if(address(currency) == address(0))
            currency = IERC20(ILiquidityManager(FunPool.liquidityManager()).WETH9());
        uint amount = currency.balanceOf(address(this));
        uint volume = token.balanceOf(address(this));
        ILocker(FunPool.locker()).collect(tokenIds[token]);
        address governor = Config.getA(_governor_);
        currency.safeTransfer(governor, currency.balanceOf(address(this)) - amount);
        token.safeTransfer(governor, token.balanceOf(address(this)) - volume);
    }

    function unlock(IERC20 token) external {
        uint tokenId = tokenIds[token];
        ILocker(FunPool.locker()).withdraw(tokenId);
        ILiquidityManager(FunPool.liquidityManager()).transferFrom(address(this), Config.getA(_governor_), tokenId);
    }
    
}
