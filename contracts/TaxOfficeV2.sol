// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

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
contract TaxOfficeV2 is Operator {
    using SafeMath for uint256;

    address public piggy = address(0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7);
    address public wavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    address public uniRouter = address(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);

    mapping(address => bool) public taxExclusionEnabled;

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(piggy).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(piggy).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(piggy).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(piggy).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(piggy).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(piggy).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(piggy).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(piggy).isAddressExcluded(_address)) {
            return ITaxable(piggy).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(piggy).isAddressExcluded(_address)) {
            return ITaxable(piggy).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(piggy).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtPiggy,
        uint256 amtToken,
        uint256 amtPiggyMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtPiggy != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(piggy).transferFrom(msg.sender, address(this), amtPiggy);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(piggy, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtPiggy;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtPiggy, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            piggy,
            token,
            amtPiggy,
            amtToken,
            amtPiggyMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if(amtPiggy.sub(resultAmtPiggy) > 0) {
            IERC20(piggy).transfer(msg.sender, amtPiggy.sub(resultAmtPiggy));
        }
        if(amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtPiggy, resultAmtToken, liquidity);
    }

    function addLiquidityETHTaxFree(
        uint256 amtPiggy,
        uint256 amtPiggyMin,
        uint256 amtFtmMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtPiggy != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(piggy).transferFrom(msg.sender, address(this), amtPiggy);
        _approveTokenIfNeeded(piggy, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtPiggy;
        uint256 resultAmtFtm;
        uint256 liquidity;
        (resultAmtPiggy, resultAmtFtm, liquidity) = IUniswapV2Router(uniRouter).addLiquidityETH{value: msg.value}(
            piggy,
            amtPiggy,
            amtPiggyMin,
            amtFtmMin,
            msg.sender,
            block.timestamp
        );

        if(amtPiggy.sub(resultAmtPiggy) > 0) {
            IERC20(piggy).transfer(msg.sender, amtPiggy.sub(resultAmtPiggy));
        }
        return (resultAmtPiggy, resultAmtFtm, liquidity);
    }

    function setTaxablePiggyOracle(address _piggyOracle) external onlyOperator {
        ITaxable(piggy).setPiggyOracle(_piggyOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(piggy).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(piggy).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}
