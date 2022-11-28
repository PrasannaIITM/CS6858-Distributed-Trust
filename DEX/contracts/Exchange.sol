//SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IExchange.sol";
import "../interfaces/IFactory.sol";

contract Exchange is ERC20 {
    address public tokenAddress;
    address public factoryAddress;


    event EthToTokenPurchase(address indexed buyer, uint256 indexed ethIn, uint256 indexed tokensOut);
    event TokenToEthPurchase(address indexed buyer, uint256 indexed tokensIn, uint256 indexed ethOut);
    event TokenToTokenPurchase(address indexed buyer, address indexed tokenIn, uint256 tokensIn, address indexed tokenOut);
    event Investment(address indexed liquidityProvider, uint256 indexed sharesPurchased);
    event Divestment(address indexed liquidityProvider, uint256 indexed sharesBurned);

    mapping(address => uint256) public shares;

    constructor(address _token) ERC20("LPToken", "LPT") {
        require(_token != address(0), "Invalid token address");

        tokenAddress = _token;
        factoryAddress = msg.sender;
    }

    // Helper functions
    function getReserve() public view returns (uint256) {
        // returns the balance of the exchange token
        return IERC20(tokenAddress).balanceOf(address(this));
    }

    function getAmount(
        uint256 inputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    ) private pure returns (uint256) {
        require(inputReserve > 0 && outputReserve > 0, "Invalid reserves");

        // uses the formula (x + delta_x)(y - delta_y) = xy

        // 0.25% transaction fee, remove it from the inputAmount, and return outputAmount
        // corresponding to only 99.75% of inputAmount
        
        uint256 inputAmountWithFee = inputAmount * 9975;
        uint256 numerator = inputAmountWithFee * outputReserve;
        uint256 denominator = (inputReserve * 10000) + inputAmountWithFee;

        return numerator / denominator;
    }


    function getTokenAmount(uint256 _ethSold) public view returns (uint256) {
        // returns token amount corresponding to eth sold
        require(_ethSold > 0, "ethSold should be greater than 0");

        uint256 tokenReserve = getReserve();

        return getAmount(_ethSold, address(this).balance, tokenReserve);
    }

    function getEthAmount(uint256 _tokenSold) public view returns (uint256) {
        // returns eth correspoding to tokens sold
        require(_tokenSold > 0, "tokenSold should be greater than 0");

        uint256 tokenReserve = getReserve();

        return getAmount(_tokenSold, tokenReserve, address(this).balance);
    }

    function ethToToken(uint256 _minTokens, address recipient) private returns(uint256){
        // finds tokens corresponding to eth sent as msg.value and trnasfers those tokens to the recipient
        uint256 tokenReserve = getReserve();
        // set input reserve as balance - msg.sender as msg.sender eths was already added to the balance
        uint256 tokensBought = getAmount(
            msg.value,
            address(this).balance - msg.value,
            tokenReserve
        );

        require(tokensBought >= _minTokens, "Insufficient output amount");

        IERC20(tokenAddress).transfer(recipient, tokensBought);

        return tokensBought;
    }

    // Main functions
    function addLiquidity(uint256 _tokenAmount)
        public
        payable
        returns (uint256)
    {
        require(_tokenAmount >= 0, "Invalid input token amount");
        // the first liquidity provider gets to set the initial exchange rate
        if (getReserve() == 0) {
            IERC20 token = IERC20(tokenAddress);
            token.transferFrom(msg.sender, address(this), _tokenAmount);

            // first liquidity provider, owns 100% shares
            uint256 liquidity = address(this).balance;
            _mint(msg.sender, liquidity);
            shares[msg.sender] += liquidity;
            emit Investment(msg.sender, liquidity);
            return liquidity;
        } else {
            // add additional liquidity in the same proportion that has already established in the pool
            uint256 ethReserve = address(this).balance - msg.value;
            uint256 tokenReserve = getReserve();

            // tokenAmount - proportional to msg.value eth
            uint256 tokenAmount = (msg.value * tokenReserve) / ethReserve;
            require(_tokenAmount >= tokenAmount, "Insufficient token amount");

            IERC20 token = IERC20(tokenAddress);
            token.transferFrom(msg.sender, address(this), tokenAmount);

            // shares of current liquidity provider proportional to their contribution in the liquidity pool
            uint256 liquidity = (msg.value * totalSupply()) / ethReserve;
            // mint new LP tokens, adjusts the percentage share of other liquidity providers accordingly
            _mint(msg.sender, liquidity);
            shares[msg.sender] += liquidity;
            emit Investment(msg.sender, liquidity);
            return liquidity;
        }
    }

    function removeLiquidity(uint256 _amount)
        public
        returns (uint256, uint256)
    {
        require(_amount > 0, "Invalid amount");
        require(_amount <= shares[msg.sender], "Attempting to remove more amount than entitled");

        // remove eth and tokens proportional to _amount LP tokens from the liquidity pool
        uint256 ethAmount = (address(this).balance * _amount) / totalSupply();
        uint256 tokenAmount = (getReserve() * _amount) / totalSupply();

        // reduces totalSupply of LP tokens by _amount, which adjusts the percentage share of active liquidity providers
        _burn(msg.sender, _amount);
        payable(msg.sender).transfer(ethAmount);
        IERC20(tokenAddress).transfer(msg.sender, tokenAmount);
        shares[msg.sender] -= _amount;
        emit Divestment(msg.sender, _amount);
        return (ethAmount, tokenAmount);
    }


    function ethToTokenTransfer(uint256 _minTokens, address _recipient)
        public
        payable
    {
        // send tokens porportional to msg.value eths to _recipient
        uint256 tokenOut = ethToToken(_minTokens, _recipient);
        emit EthToTokenPurchase(msg.sender, msg.value, tokenOut);
    }

    function ethToTokenSwap(uint256 _minTokens) public payable {
        // swap msg.value eths for tokens
        uint256 tokenOut = ethToToken(_minTokens, msg.sender);
        emit EthToTokenPurchase(msg.sender, msg.value, tokenOut);
    }

    function tokenToEthSwap(uint256 _tokensSold, uint256 _minEth) public {
        // swap _tokensSold tokens for eth
        uint256 tokenReserve = getReserve();
        uint256 ethBought = getAmount(
            _tokensSold,
            tokenReserve,
            address(this).balance
        );

        require(ethBought >= _minEth, "Insufficient output amount");

        IERC20(tokenAddress).transferFrom(
            msg.sender,
            address(this),
            _tokensSold
        );
        payable(msg.sender).transfer(ethBought);
        emit TokenToEthPurchase(msg.sender, _tokensSold, ethBought);
    }

    function tokenToTokenSwap(
        uint256 _tokensSold,
        uint256 _minTokensBought,
        address _tokenAddress
    ) public {
        // swap _tokensSold amount of tokens from this exchange with _tokenAddress tokens
        address exchangeAddress = IFactory(factoryAddress).getExchange(
            _tokenAddress
        );
        require(
            exchangeAddress != address(this) && exchangeAddress != address(0),
            "Invalid exchange address"
        );

        uint256 tokenReserve = getReserve();
        uint256 ethBought = getAmount(
            _tokensSold,
            tokenReserve,
            address(this).balance
        );

        IERC20(tokenAddress).transferFrom(
            msg.sender,
            address(this),
            _tokensSold
        );

        IExchange(exchangeAddress).ethToTokenTransfer{value: ethBought}(
            _minTokensBought,
            msg.sender
        );
        emit TokenToTokenPurchase(msg.sender, tokenAddress, _tokensSold, _tokenAddress);
    }   
}