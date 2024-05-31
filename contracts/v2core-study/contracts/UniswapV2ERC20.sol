pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';


//  V2ERC20的概念相当于是份额（股），但实际上是一种可以互相转账的 ERC20 代币
contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    uint8 public constant decimals = 18;
    uint  public totalSupply;
    mapping(address => uint) public balanceOf; // 假设总池子五百万，有个做市商加了 USDT/USDC 交易对，其中各一百万，也就是说该做市商持有价值两百万，占总池子的40%。
    mapping(address => mapping(address => uint)) public allowance;

    // 域 分隔符
    bytes32 public DOMAIN_SEPARATOR;
    // 授权的哈希
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // 用于 permit 方法里
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid // 链 id，0.8.0版本后用 block.chainId 获取
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    /**
     * mint 函数
     * @param to 
     * @param value 
     * 
     * mint 实际上是凭空增发出了代币，总供应量增加，同时给mint to 地址余额增加。
     * mint 事件相当于是从黑洞地址转出来的代币，因此也需要发送 Transfer 事件。
     */
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    // 授权额度给 spender ，最多可以转出账户内 value 余额。
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }


    // 授权
    // v,r,s中带有 owner 的签名，验证签名后可以给 spender 授权额度
    // 任何人都可以拿着用户的签名，调用 permit 函数，以用户的名义发送签名。但 gas 需要调用人支付。
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        // eip712离线签名规范
        
        // 用 owner 等参数才能构造出 digest，用于恢复出来签名者地址
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        // ecrecover函数可以从hash、签名中恢复出签名者的地址
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 要求签名者不可是零地址，恢复出来的地址必须是函数参数 owner
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}
