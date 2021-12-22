// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";

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
contract TaxOffice is Operator {
    address public piggy;

    constructor(address _piggy) public {
        require(_piggy != address(0), "piggy address cannot be 0");
        piggy = _piggy;
    }

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
        return ITaxable(piggy).excludeAddress(_address);
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(piggy).includeAddress(_address);
    }

    function setTaxablePiggyOracle(address _piggyOracle) external onlyOperator {
        ITaxable(piggy).setPiggyOracle(_piggyOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(piggy).setTaxOffice(_newTaxOffice);
    }
}
