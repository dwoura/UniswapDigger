# Uniswap V2 Core
## 新特性
### 交易对 Pairs
### 价格预言机 Price Oracle
#### 原有的安全缺陷
V2 改进了 V1 中价格容易被操控的安全缺陷。在 V1 中，攻击者在一个原子交易中，可以操控价格并触发衍生品合约的清算，随后进行交易进行攻击。因为采样价格是瞬时的，通过买卖大额代币可以操纵实时的价格。

#### 改进缺陷的措施
V2 对 V1 预言机功能进行了改进。在每一个区块的首笔交易前（等价于上个区块的尾笔交易后）计算与记录价格，这样可以使得价格操纵更加困难。

具体是通过引入了 TWAP（时间加权平均价格）来改进缺陷。为什么使用 TWAP 可以改进？因为 TWAP 的计算方式，**提高了套利者或矿工的操纵成本**、**更贴近市场真实的价格**，增强了预言机的可靠性。

V2 合约中包含有 **时间增量、价格累积器** 状态。对于时间增量，是当前区块的时间戳与上次更新时的时间戳的差值；对于价格累积器，记录的是 交易前的即时价格 与 时间增量 公式关系的累加值。值得注意的是，**价格累积器是在每笔交易执行后立即更新状态**，而不是在区块最后一笔交易后才更新。

其中的首笔交易前和尾笔交易后，可以看作是连续的两个区块之间进行的操作。通过**每笔交易中检测区块号是否与上次更新的区块号**相同，实现抽象意义上的“区块间间隙”的操作。

虽然有所改进，**但是 V2 仍旧不够健壮**，不过在 V3 中有所改进。

### 协议手续费 Protocal Fee
手续费的计算，重要的是确定两个状态：交易前与交易后。
许多笔交易完成后，手续费会累加在池子里使得池子变大，可以随着用户的 mint、burn操作，跟着分发其

### 其他...

## 代码层面


# Uniswap V3 Core
## 新特性
+ xxx
+ xxx

## 代码层面

# Uniswap V2与V3的对比与总结