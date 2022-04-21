// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
import "@openzeppelin/contracts/math/Math.sol";
import "./AcaiToken.sol";
import "./SafeTransferEth.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IWETH.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";

contract LiquidityManager is Ownable {
    AcaiToken immutable public token;
    IERC20 immutable public iloToken;
    IUniswapV2Router02 immutable public router;
    IUniswapV2Pair public pair;
    address immutable public ILOContract;

    constructor (AcaiToken _token, IERC20 _iloToken, address _ILOContract, IUniswapV2Router02 _router) public {
        token = _token;
        iloToken = _iloToken;
        ILOContract = _ILOContract;
        router = _router;
    }

    event Reedemed(address indexed account, uint256 tokenAmount, uint256 ethAmount);
    event PoolCreated(address poolAddress, uint tokenAmount, uint ethAmount);

    function createPool(uint tokenAmount, uint ethAmount) external returns (uint amountToken, uint amountETH, uint liquidity) {
        require(msg.sender == ILOContract || msg.sender == owner());
        require(token.balanceOf(address(this)) >= tokenAmount);
        require(iloToken.balanceOf(address(this)) >= ethAmount);
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        require(factory.getPair(address(iloToken), address(token)) == address(0), "pool exists");
        token.approve(address(router), tokenAmount);
        iloToken.approve(address(router), ethAmount);
        (amountToken, amountETH, liquidity) = 
            router.addLiquidity(address(token), address(iloToken), tokenAmount, ethAmount, tokenAmount, ethAmount, address(this), block.timestamp + 600);
        require(liquidity != 0, "pool creation failure");
        pair = IUniswapV2Pair(factory.getPair(address(iloToken), address(token)));
        require(address(pair) != address(0), "pool creation failure");
        //approve spending lp tokens for future redemptions
        pair.approve(address(router), 2**255);

        emit PoolCreated(address(pair), tokenAmount, ethAmount);
    }

    function getBalancesInLP() public view returns (uint tokenBalance, uint ethBalance, uint ownedLPSupply) {
        require(address(pair) != address(0), "pair not initialized");
        uint totalLPSupply = pair.totalSupply();
        ownedLPSupply = pair.balanceOf(address(this));
        uint pairTokenBalance = token.balanceOf(address(pair));
        uint pairEthBalance = iloToken.balanceOf(address(pair));
        tokenBalance = pairTokenBalance*ownedLPSupply/totalLPSupply;
        ethBalance = pairEthBalance*ownedLPSupply/totalLPSupply;
    }

    function getMinimumValue(uint tokensToRedeem) public view returns (uint ethForTokens, uint liquidityTokens) {
        (uint tokensOwnedInLP, uint ethOwnedInLP, uint ownedLPSupply) = getBalancesInLP();
        uint halfOfTokenSupply = token.totalSupply()/2;

        //calculate LP balances as if half of token supply was in the pool owned by this contract
        uint ethForRedemption = ethOwnedInLP;
        //price is higher than the redemption price
        if(halfOfTokenSupply > tokensOwnedInLP) {
            uint toBeVirtuallySold = halfOfTokenSupply - tokensOwnedInLP;
            uint ethOut = getAmountOutFeeless(toBeVirtuallySold, tokensOwnedInLP, ethOwnedInLP);
            uint ethOwnedAfterSale = ethOwnedInLP-ethOut;
            ethForRedemption = ethOwnedAfterSale;
        }
        else if (halfOfTokenSupply < tokensOwnedInLP) {
            //simulate balance in equilibrium
            uint tokensToBeVirtuallyBought = tokensOwnedInLP-halfOfTokenSupply;
            //feeless because eth for fees doesn't exist in lp
            uint virtualEthIn = getAmountInFeeless(tokensToBeVirtuallyBought, ethOwnedInLP, tokensOwnedInLP);
            ethForRedemption = ethOwnedInLP + virtualEthIn;
        }
        ethForTokens = ethForRedemption*tokensToRedeem/halfOfTokenSupply;
        liquidityTokens = ownedLPSupply*ethForTokens/ethOwnedInLP;
    }


    function redeemForMinimumValue(uint tokensToRedeem) public returns (uint ethAmount) {
        require(token.transferFrom(msg.sender, address(this), tokensToRedeem));
        (uint ethForTokens, uint equivalentLPTokens) = getMinimumValue(tokensToRedeem);
        require(ethForTokens > 0 && equivalentLPTokens > 0, "redeem amount too low");
        (uint amountToken, uint amountETH) = router.removeLiquidityETH(address(token), equivalentLPTokens, 0, 0, address(this), block.timestamp);
        //min because it's possible for one unit of liquidity to mean more than 1 wei - negligible rounding error
        token.burn(token.balanceOf(address(this)));
        ethAmount = Math.min(ethForTokens, amountETH);
        SafeTransferEth.transferEth(msg.sender, ethAmount);

        emit Reedemed(msg.sender, tokensToRedeem, ethAmount);
    }

    function withdrawToken(IERC20 _token, address recipient, uint amount) external onlyOwner returns (uint) {
        if(amount == 0) {
            amount = _token.balanceOf(address(this));
        }
        require(_token.transfer(recipient, amount));
        return amount;
    }

    function withdrawEth(uint amount, address recipient) external onlyOwner returns (uint) {
        if(amount == 0) {
            amount = address(this).balance;
        }
        SafeTransferEth.transferEth(recipient, amount);
        return amount;
    }

    receive() external payable {}

    // given an output amount of an asset and pair reserves, returns the required input amount of the other asset
    function getAmountInFeeless(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        uint numerator = reserveIn*amountOut;
        uint denominator = reserveOut-amountOut;
        amountIn = (numerator / denominator)+1;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOutFeeless(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        uint numerator = amountIn*reserveOut;
        uint denominator = reserveIn + amountIn;
        amountOut = numerator / denominator;
    }
}