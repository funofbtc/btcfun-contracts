// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma abicoder v2;

import "./Include.sol";
import "./iZiSwap.sol";

//新需求：
//1. 单个offer不到他地址的cap上限 可以一直打。（目前看已经是这样了）
//2. 募资到时间没成功退款 需要有个合约自动退款 但退款需要扣除 X% 作为gas的补偿和手续费 （需要添加处理下，X%可以管理员修改）
//单独地址收费，可以配置收费地址？失败成功，不成功 都收5%。（sets一个收费地址）
//（募资手续费 5%，交易手续费【1%，0.3%， 0.05%， 0.01%】选择一个，我们取1%）两个费率都测试一下。

contract BtcFun is Sets {
	using SafeERC20 for IERC20;

    bytes32 internal constant _feeRate_             = "feeRate";
    int24 internal constant _feeRate_5pct_          = 59918;       // = -log(0.05^2, 1.0001)

    //token信息最好一个结构体管理，更清晰明了。


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

    modifier pauseable {
        require(Config.get("pause") == 0, "paused");
        _;
    }

    //作废代码直接删除就好，不用保留。

    function createPool(IERC20 token, IERC20 currency, uint amount, uint quota, uint start, uint expiry, uint pre) external payable nonReentrant pauseable {
        require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        uint totalSupply = token.totalSupply();
        require(totalSupply == ICappedERC20(address(token)).cap() && totalSupply == token.balanceOf(msg.sender), "not all token");
        token.transferFrom(msg.sender, address(this), totalSupply);
        string memory name = ERC20(address(token)).symbol();
        require(tokens[name] == IERC20(address(0)), "Token exists!");
        tokens[name] = token;
        currencies[token] = currency;
        amounts[token] = amount;
        quotas[token] = quota;

        //截止时间判断：start<expiry and block.time<expiry
        starts[token] = start;
        expiries[token] = expiry;
        FunPool.createPool(address(token), totalSupply / 2, address(currency), amount);
        emit CreatePool(name, totalSupply, token, currency, amount, quota, start, expiry);
        if(pre > 0)
            _offer(token, pre);
    }
    event CreatePool(string indexed name, uint totalSupply, IERC20 indexed token, IERC20 indexed currency, uint amount, uint quota, uint start, uint expiry);

    //函数名更新：getValidAmount
	function checkAmount(IERC20 token, uint amount) public view returns(uint) {
        uint quota = quotas[token];
        uint offered = offeredOf[token][msg.sender];
        if(!isGovernor() && quota > 0 && amount + offered > quota)
		    amount = quota > offered ? quota - offered : 0;
        if(amount + totalOffered[token] > amounts[token])
            amount = amounts[token] - totalOffered[token];
        return amount;
    }

    //签名一般有截止时间，只在一定时间段有效
    //现在ecrecovery验证签名，审计说有可扩展性攻击问题，导致多个签名都可以验签通过。推荐用ECDSA.recover校验，参考之前给的例子。
    function offer(IERC20 token, uint amount, uint8 v, bytes32 r, bytes32 s) public payable nonReentrant pauseable {
        //amount + token，进行校验。
        //require(amount > 0, "invalid amount");
        //require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");

		require(Config.getA("signatory") == ecrecover(keccak256(abi.encode(FunPool.chainId(), token, msg.sender, offeredOf[token][msg.sender], amount)), v, r, s), "invalid signature");
        _offer(token, amount);
    }

	function _offer(IERC20 token, uint amount) internal {
        IERC20 currency = currencies[token];
		require(block.timestamp >= starts[token], "it's not time yet");
		require(block.timestamp <= expiries[token], "expired");
        //validAmount = getValidAmount(token, amount) 后面都是 validAmount
        amount = checkAmount(token, amount);
		require(amount > 0, "no quota");
		//require(offeredOf[token][msg.sender] == 0, "offered already");
        //每个人可以募资多次么？
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
        //事件添加 currency字段
		emit Offer(token, msg.sender, amount, offeredOf[token][msg.sender], totalOffered[token]);
        if(totalOffered[token] >= amounts[token])
            //金额也加上，OfferCompleted(token, currency, totalOffered[token]);
            emit Completed(token);
	}
	event Offer(IERC20 indexed token, address indexed addr, uint amount, uint offered, uint total);
    event Completed(IERC20 indexed token);

    //命名 airdropAccount
    //参数 sender 统一改成 to
    function airdropAccount(IERC20 token, address to) internal {
        require(totalOffered[token] == amounts[token], block.timestamp <= expiries[token] ? "offer unfinished" : "offer failed, call refund instead");

        //这里addPool最后一个参数什么意思，是不是collect受益人？要不要单独配置？ Config.getA(_governor_)，
        if(token.balanceOf(address(this)) == token.totalSupply())
            //** 实际merlinswap扣走95%，转给收费地址剩余的amount
            tokenIds[token] = FunPool.addPool(address(token), token.totalSupply()/2, address(currencies[token]), amounts[token], int24(int(Config.get(_feeRate_))), Config.getA(_governor_));
        require(offeredOf[token][to] >  0, "not offered");
        require(claimedOf[token][to] == 0, "claimed already");

        uint volume = offeredOf[token][to] * IERC20(token).totalSupply() / 2 / amounts[token];
        claimedOf[token][to] = volume;
        token.safeTransfer(to, volume);
        //emit AirdropAccount(msg.sender, token, to, volume, currency, offeredOf[token][sender]);
        emit Claim(token, to, volume);
    }
    event Claim(IERC20 indexed token, address indexed addr, uint volume);

    //定义maxAirdropCount = 500，每次最多给500个用户空投
    //命名 airdrop
    function airdrop(IERC20 token, uint offset, uint count) external nonReentrant pauseable {
        //require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        //require(count > 0 && count <= maxAirdropCount, "invalid count");
        //require(offset < offerors[token].length, "invalid offset");

        uint N = Math.min(offset + count, offerorN(token));

        for(uint i = offset; i < N; i++) {
            //参数 sender 统一改成 to
            address to = offerors[token][i];
            if(claimedOf[token][to] == 0)
                _claim(token, to);
        }
    }

    //命名 refund
    //参数 sender 统一改成 to
    function refund(IERC20 token, uint offset, uint count) external nonReentrant pauseable {
        //require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        //require(count > 0 && count <= maxAirdropCount, "invalid count");
        //require(offset < offerors[token].length, "invalid offset");

        uint N = Math.min(offset + count, offerorN(token));
        for(uint i = offset; i < N; i++) {
            //参数 sender 统一改成 to
            address sender = offerors[token][i];
            if(offeredOf[token][sender] > 0)
                _refund(token, sender);
        }
    }

    //命名 refundAccount
    //参数 sender 统一改成 to
    function refundAccount(IERC20 token, address sender) internal {
        //require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        require(block.timestamp > expiries[token], "not expired yet");
        require(totalOffered[token] < amounts[token], "offer finished, call claim instead"); // call airdrop instead
        uint amount = offeredOf[token][sender];
        require(amount > 0, "not offered or refund already");
        offeredOf[token][sender] = 0;
		IERC20 currency = currencies[token];
        if(address(currency) == address(0))
            Address.sendValue(payable(sender), amount);
        else
            currency.safeTransfer(sender, amount);
        emit Refund(token, sender, amount); //添加 currency 字段
    }
    event Refund(IERC20 indexed token, address indexed addr, uint amount);

    function collect(IERC20 token) external nonReentrant pauseable {
        //require(FunPool.bridged().erc20TokenInfoSupported(token), "token is not bridged");
        IERC20 currency = currencies[token];
        if(address(currency) == address(0))
            currency = IERC20(ILiquidityManager(FunPool.liquidityManager()).WETH9());
        uint amount = currency.balanceOf(address(this));
        uint volume = token.balanceOf(address(this));
        ILocker(FunPool.locker()).collect(tokenIds[token]);
        //governor接收人是否单独配置，governor 后面是多签管理。
        address governor = Config.getA(_governor_);
        currency.safeTransfer(governor, currency.balanceOf(address(this)) - amount);
        token.safeTransfer(governor, token.balanceOf(address(this)) - volume);
    }

    function unlock(IERC20 token) external nonReentrant pauseable {
        uint tokenId = tokenIds[token];
        ILocker(FunPool.locker()).withdraw(tokenId);
        ILiquidityManager(FunPool.liquidityManager()).transferFrom(address(this), Config.getA(_governor_), tokenId);
    }
    
}
