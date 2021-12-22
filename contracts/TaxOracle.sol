// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ________  ___  ________  ________      ___    ___      ________ ___  ________   ________  ________   ________  _______      
|\   __  \|\  \|\   ____\|\   ____\    |\  \  /  /|    |\  _____\\  \|\   ___  \|\   __  \|\   ___  \|\   ____\|\  ___ \     
\ \  \|\  \ \  \ \  \___|\ \  \___|    \ \  \/  / /    \ \  \__/\ \  \ \  \\ \  \ \  \|\  \ \  \\ \  \ \  \___|\ \   __/|    
 \ \   ____\ \  \ \  \  __\ \  \  ___   \ \    / /      \ \   __\\ \  \ \  \\ \  \ \   __  \ \  \\ \  \ \  \    \ \  \_|/__  
  \ \  \___|\ \  \ \  \|\  \ \  \|\  \   \/  /  /        \ \  \_| \ \  \ \  \\ \  \ \  \ \  \ \  \\ \  \ \  \____\ \  \_|\ \ 
   \ \__\    \ \__\ \_______\ \_______\__/  / /           \ \__\   \ \__\ \__\\ \__\ \__\ \__\ \__\\ \__\ \_______\ \_______\
    \|__|     \|__|\|_______|\|_______|\___/ /             \|__|    \|__|\|__| \|__|\|__|\|__|\|__| \|__|\|_______|\|_______|
                                      \|___|/                                                                                
                                                                                                                             
    https://piggyfinance.io
*/
contract PiggyTaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public piggy;
    IERC20 public wavax;
    address public pair;

    constructor(
        address _piggy,
        address _wavax,
        address _pair
    ) public {
        require(_piggy != address(0), "piggy address cannot be 0");
        require(_wavax != address(0), "wavax address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        piggy = IERC20(_piggy);
        wavax = IERC20(_wavax);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(piggy), "token needs to be piggy");
        uint256 piggyBalance = piggy.balanceOf(pair);
        uint256 wavaxBalance = wavax.balanceOf(pair);
        return uint144(piggyBalance.mul(_amountIn).div(wavaxBalance));
    }

    function getPiggyBalance() external view returns (uint256) {
	return piggy.balanceOf(pair);
    }

    function getBtcbBalance() external view returns (uint256) {
	return wavax.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 piggyBalance = piggy.balanceOf(pair);
        uint256 wavaxBalance = wavax.balanceOf(pair);
        return piggyBalance.mul(1e18).div(wavaxBalance);
    }

    function setPiggy(address _piggy) external onlyOwner {
        require(_piggy != address(0), "piggy address cannot be 0");
        piggy = IERC20(_piggy);
    }

    function setWavax(address _wavax) external onlyOwner {
        require(_wavax != address(0), "wavax address cannot be 0");
        wavax = IERC20(_wavax);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }



}
