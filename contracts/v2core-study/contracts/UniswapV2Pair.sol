pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

// 基本公式 x*y=k, 实际逻辑上会对公式有一些变形
// 注意常数 k 用两资产数量乘积表示，而流动性数量liquidity用两资产数量乘积的开平方表示。
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224; // 定点数，把 UQ112x112 库绑定到 uint224 类型，这样可以在 uint224类型的变量上直接调用如.encode().decode()库函数。

    // 最小流动性，十的三次方 1000wei
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 函数选择器，通过包装 函数名和参数类型的字符串 获取哈希值前四个字节。
    // calldata 的前四个字节，可以指定要调用哪个函数，这四个字节就叫函数选择器
    // 等同于IERC20.transfer.selector
    // 注意，1字节(byte)=8个2进制数=2个16进制数，即函数选择器4个字节有8个16进制数，例如0x60fe47b1这种形式
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory; //工厂合约地址
    address public token0; // 十六进制数值相对于另一token小的 token 地址
    address public token1; // 数值大的

    // 关键变量
    // reserve0、reserve1表示当前池子的深度，即 token0、token1的代币余额，也可以理解成缓存余额
    // 缓存余额用于旧状态的公式计算,
    // 还可以用于计算协议手续费，由于外部都可以转入代币进如合约，要想获取所转入的数额（加池子的数额），就需要通过最新余额 balance 与缓存余额 reserve 相减来取得。
    // 保存缓存余额是为了防止攻击者操控价格预言机。这是如何做到的？ 这是 TWAP 机制决定的。
    // 这是因为缓存余额的更新是在区块结束后执行的，而不是每笔交易后执行。原理：每次交易中，合约会检查是否与上个区块号相同，不同则说明进入新的区块中，则更新reserve。
    uint112 private reserve0;           // 使用单个存储插槽，可以通过getReserves函数访问
    // 使用uint112是实用性，节省存储。uq112x112 可以存储在uint224中，并在256位中剩余32位空余空间供时间戳使用。
    //   补充：256位指的是以太坊智能合约中的数据存储在 256 位的槽（slot）中，单个存储插槽即256位，实用性指的是是充分利用slot。
    // V2的储备余额只能支持最高2^112-1的数量，在_update()函数中会检查是否超出。
    // 如果超出了，任何用户都可以调用 skim()来转出超额的流动性，恢复到正常流动性状态。
    uint112 private reserve1;           // 使用单个存储插槽，可以通过getReserves函数访问
    // 时间戳也是 TWAP 机制的关键变量，使用 uint32。正好能够与前两个112位的reserve 一起打包成256位的数据。
    // 但是实际上由于某些填充规则会用到两个slot。   reserve0和reserve1存在一个插槽，blockTimestampLast单独存在另一个插槽。
    uint32  private blockTimestampLast; // 使用单个存储插槽，可以通过getReserves函数访问

    // 价格累加器，用于价格预言，在链下使用
    // 累加器记录了所交互的区块开始处（等价于上一个区块结束后）的价格的累加和，累加器的值在更新的那一刻后的值，即为合约历史上每秒的现货价格之和
    // 若要计算t1到t2时刻的TWAP价格（时间加权平均价格），外部可以检查t1和t2时间的累加器的值，通过后值减去前值，再除以期间经过的秒数，就可以计算出以秒为单位的TWAP价格
    //   补充：合约本身不记录历史累加值，只有最新的累加值，要在链下记录历史累加值。
    uint public price0CumulativeLast; // 记录的是 Token0对Token1的累计价格
    // 某段时间内用 B 计算的 A 的均价不一定等于用 A 计算 B 均价的倒数。
    // 例如，USDT/ETH 在区块1中价格为100，在区块2中为300，则 USDT/ETH 的均价为200。
    // 但ETH/USDT的均价有可能是1/150，可以知道他们的均价并非倒数关系。 ？？？？这一块不太理解为什么
    // 因此两个方向的价格都要都要追踪，用户自行选用。
    uint public price1CumulativeLast; // 记录的是 Token1对Token0的累计价格

    // 最近一次的缓存余额的乘积，计算常数K，用于计算费率 
    // kLast记录的是上一次交易时的两种资产数量的乘积
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    // 锁定修饰器，为函数加锁
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 一次查询出来比单独查询出来要节省 gas
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 给 to 地址转账 value 个 token
    function _safeTransfer(address token, address to, uint value) private {
        // call方法调用 transfer 转账方法，用到函数选择器
        // call 方法会发送 calldata，前四个字节为指定调用 transfer 方法的函数选择器。
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 要求 call 后返回的 success 为 true，且data有内容或者 data 为 true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 部署时，工厂合约会调用这个方法
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 这个低级函数应被call在执行安全检查的合约里
    // 外部函数，铸造流动性代币lp，并发送到指定的 to 地址里
    // 返回值 liquidity 是所要铸造流动性代币的数量
    function mint(address to) external lock returns (uint liquidity) {
        // 这种读变量的方式能够减少存储（slot）读取的操作。 ？？？
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // 省 gas
        // this是调用函数的合约的实例。一个合约可以有多个实例
        // 作用是读取本合约里有多少 token0 和 token1的数量
        uint balance0 = IERC20(token0).balanceOf(address(this)); // address(this)表示本pair合约地址
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // 现有余额减去缓存余额，通过算出差值可以知道比上次增加了多少数量，用于计算外部加了lp多少数量。
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        // 传入缓存余额，计算手续费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 可节约gas，_mintFee函数执行后会使得总供应（总流动性）变化，因此_totalSupply变量应在变化后读取，避免重复读取。
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // 如果该 pair 没有流动性，则算出流动性后进行铸造
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY); // 用开方的形式表示流动性数量
           // 初始流动性的创建，要先给0地址铸造最小流动性
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens 永久锁定第一个最小流动性
        } else {
            // 若该 pair 已经存在了流动性
            // 应该是 _totalSupply * (amount/_reserve) ， 计算加 lp 的数量占原池子余额的占比，再乘上总供应数量，即可得出需要增发的交易对token数量liquidity
            // 选用较小值可以保证交易对比例。如果选用较大值，另一种资产数量不够，导致比例失衡。
            // 可能会存在另一种 token 出现多余的数额，会在外围合约里的addLiquidity函数里进行退还。  ！！！具体实现暂未了解，这块还要继续研究。！！！
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 确保新铸造的流动性份额大于零后，给创建者地址铸造对应流动性数额的池子 token
        // 给目标地址，增发对应流动性数额
        _mint(to, liquidity);

        // 更新缓存余额、累加值。现有余额在计算后并入流动性，成为缓存余额
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果费率开启了，则还需要更新最近常数k，因为
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
