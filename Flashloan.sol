pragma solidity ^0.5.12;

import "./IERC20.sol";

//UniswapV2Pair 
interface pair{
    //借钱
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}
//UniswapV2Router02
interface router{
    //通过精确token交换token
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts); 
    //算出还钱的金额 计算当希望获得一定数量（amountOut）的代币B时，应该输入多少数量（amoutnIn）的代币A
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
    //计算在使用多个交易对时，输入一定数量（amountIn）的第一种代币，最终能收到多少数量的最后一种代币
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}


interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

contract FlashLoan {
    address public USDTETH = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
    address public USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public uniV2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    bytes _calldata = bytes("FlashLoan");
    event Balance(address asset, uint256 amount);

    uint256 loanAmount;
    uint256 amountIn;
    
    constructor() public{
        //批准当前合约的WETH给路由合约使用(无限量)
        safeApprove(WETH,uniV2,uint256(-1));
        safeApprove(USDT,uniV2,uint256(-1));
        safeApprove(USDC,uniV2,uint256(-1));
    }
    function() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }
    //把账号的钱打到合约中，在还钱时除了借款之外，消耗的手续费、滑点、利息需要算上
    function deposit()public payable{
        amountIn = address(this).balance;
        IWETH(WETH).deposit.value(amountIn)();
    }
    //合约的余额转回账号
    function withdraw()public{
        uint256 balance = IERC20(WETH).balanceOf(address(this));
        emit Balance(address(this), balance);
        IWETH(WETH).withdraw(balance);
        emit Balance(address(this), address(this).balance);
        msg.sender.transfer(balance);
        amountIn = 0;
    }
    
    //要交换的交易对
    function paths()public view 
    returns(
        address[] memory path1,
        address[] memory path2,
        address[] memory path3,
        address[] memory path4,
        address[] memory path5,
        address[] memory path6
    ){
        //USDT - USDC
        path1 = new address[](2);
        path1[0] = USDT;
        path1[1] = USDC;
        //USDC - WETH
        path2 = new address[](2);
        path2[0] = USDC;
        path2[1] = WETH;
        //WETH - USDT
        path3 = new address[](2);
        path3[0] = WETH;
        path3[1] = USDT;
        //USDT - WETH
        path4 = new address[](2);
        path4[0] = USDT;
        path4[1] = WETH;
        //WETH - USDC
        path5 = new address[](2);
        path5[0] = WETH;
        path5[1] = USDC;
        //USDC - USDT 
        path6 = new address[](2);
        path6[0] = USDC;
        path6[1] = USDT;
    }
    
    //1.借钱 从USDTETH交易对中借出ETH
    function swap(uint256 _loanAmount) public{
        loanAmount = _loanAmount;
        pair(USDTETH).swap(uint(0),loanAmount,address(this),_calldata);
        emit Balance(WETH,amountIn - IERC20(WETH).balanceOf(address(this)));
    }

    //2.借钱后的处理，并还钱
    //UniswapV2Pair 回调函数 (借到钱后)
    //USDT - USDC - WEHT - USDT
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes memory data) public{
        uint balance = IERC20(USDT).balanceOf(address(this));
        emit Balance(USDT,balance);
        //USDT(借到) - USDC 
        (address[] memory path1,address[] memory path2,address[] memory path3,,,) = paths();
        uint[] memory amounts1 = router(uniV2).swapExactTokensForTokens(loanAmount,uint(0),path1,address(this),block.timestamp+1800);
        emit Balance(USDC,amounts1[1]);
        //USDC - WETH
        uint[] memory amounts2 = router(uniV2).swapExactTokensForTokens(amounts1[1],uint(0),path2,address(this),block.timestamp+1800);
        emit Balance(WETH,amounts2[1]);
        //WETH - USDT(还回去)
        uint[] memory amounts3 = router(uniV2).getAmountsIn(loanAmount, path3);
        //把借款还给交易对
        IERC20(WETH).transfer(USDTETH,amounts3[0]);
        
        emit Balance(WETH,IERC20(WETH).balanceOf(address(this)));
    }
    //计算WETH - USDT - USDC - WETH 这个交换下来损失多少
    function calcA(uint256 _amountIn) public view returns(uint256){
        (address[] memory path1,address[] memory path2,address[] memory path3,,,) = paths();
        
        uint[] memory amounts1 = router(uniV2).getAmountsOut(_amountIn, path3);
        uint[] memory amounts2 = router(uniV2).getAmountsOut(amounts1[1], path1);
        uint[] memory amounts3 = router(uniV2).getAmountsOut(amounts2[1], path2);
        return _amountIn - amounts3[1];
    }
    //计算WETH - USDC - USDT - WETH 这个交换下来损失多少
    function calcB(uint256 _amountIn) public view returns(uint256){
        (,,,address[] memory path4,address[] memory path5,address[] memory path6) = paths();
        
        uint[] memory amounts1 = router(uniV2).getAmountsOut(_amountIn, path5);
        uint[] memory amounts2 = router(uniV2).getAmountsOut(amounts1[1], path6);
        uint[] memory amounts3 = router(uniV2).getAmountsOut(amounts2[1], path4);
        return _amountIn - amounts3[1];
        
    }
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }
}