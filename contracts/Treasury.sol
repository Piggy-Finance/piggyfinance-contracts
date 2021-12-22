// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IMasonry.sol";

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
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public piggy;
    address public pbond;
    address public pshare;

    address public masonry;
    address public piggyOracle;

    // price
    uint256 public piggyPriceOne;
    uint256 public piggyPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of PIGGY price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochPiggyPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra PIGGY during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public communityFund;
    uint256 public communityFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 piggyAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 piggyAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event MasonryFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event CommunityFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getPiggyPrice() > piggyPriceCeiling) ? 0 : getPiggyCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(piggy).operator() == address(this) &&
                IBasisAsset(pbond).operator() == address(this) &&
                IBasisAsset(pshare).operator() == address(this) &&
                Operator(masonry).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getPiggyPrice() public view returns (uint256 piggyPrice) {
        try IOracle(piggyOracle).consult(piggy, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult PIGGY price from the oracle");
        }
    }

    function getPiggyUpdatedPrice() public view returns (uint256 _piggyPrice) {
        try IOracle(piggyOracle).twap(piggy, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult PIGGY price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnablePiggyLeft() public view returns (uint256 _burnablePiggyLeft) {
        uint256 _piggyPrice = getPiggyPrice();
        if (_piggyPrice <= piggyPriceOne) {
            uint256 _piggySupply = getPiggyCirculatingSupply();
            uint256 _bondMaxSupply = _piggySupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(pbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnablePiggy = _maxMintableBond.mul(_piggyPrice).div(1e18);
                _burnablePiggyLeft = Math.min(epochSupplyContractionLeft, _maxBurnablePiggy);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _piggyPrice = getPiggyPrice();
        if (_piggyPrice > piggyPriceCeiling) {
            uint256 _totalPiggy = IERC20(piggy).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalPiggy.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _piggyPrice = getPiggyPrice();
        if (_piggyPrice <= piggyPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = piggyPriceOne;
            } else {
                uint256 _bondAmount = piggyPriceOne.mul(1e18).div(_piggyPrice); // to burn 1 PIGGY
                uint256 _discountAmount = _bondAmount.sub(piggyPriceOne).mul(discountPercent).div(10000);
                _rate = piggyPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _piggyPrice = getPiggyPrice();
        if (_piggyPrice > piggyPriceCeiling) {
            uint256 _piggyPricePremiumThreshold = piggyPriceOne.mul(premiumThreshold).div(100);
            if (_piggyPrice >= _piggyPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _piggyPrice.sub(piggyPriceOne).mul(premiumPercent).div(10000);
                _rate = piggyPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = piggyPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _piggy,
        address _pbond,
        address _pshare,
        address _piggyOracle,
        address _masonry,
        uint256 _startTime
    ) public notInitialized {
        piggy = _piggy;
        pbond = _pbond;
        pshare = _pshare;
        piggyOracle = _piggyOracle;
        masonry = _masonry;
        startTime = _startTime;

        piggyPriceOne = 10**18; // This is to allow a PEG of 1 PIGGY per AVAX
        piggyPriceCeiling = piggyPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 5000 ether, 10000 ether, 15000 ether, 20000 ether, 50000 ether, 100000 ether, 200000 ether, 500000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for masonry
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn PIGGY and mint pBOND)
        maxDebtRatioPercent = 3500; // Upto 35% supply of pBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(piggy).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setMasonry(address _masonry) external onlyOperator {
        masonry = _masonry;
    }

    function setPiggyOracle(address _piggyOracle) external onlyOperator {
        piggyOracle = _piggyOracle;
    }

    function setPiggyPriceCeiling(uint256 _piggyPriceCeiling) external onlyOperator {
        require(_piggyPriceCeiling >= piggyPriceOne && _piggyPriceCeiling <= piggyPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        piggyPriceCeiling = _piggyPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _communityFund,
        uint256 _communityFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_communityFund != address(0), "zero");
        require(_communityFundSharedPercent <= 500, "out of range"); // <= 5%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 500, "out of range"); // <= 5%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        communityFund = _communityFund;
        communityFundSharedPercent = _communityFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= piggyPriceCeiling, "_premiumThreshold exceeds piggyPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatePiggyPrice() internal {
        try IOracle(piggyOracle).update() {} catch {}
    }

    function getPiggyCirculatingSupply() public view returns (uint256) {
        IERC20 piggyErc20 = IERC20(piggy);
        uint256 totalSupply = piggyErc20.totalSupply();
        uint256 balanceExcluded = 0;
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _piggyAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_piggyAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 piggyPrice = getPiggyPrice();
        require(piggyPrice == targetPrice, "Treasury: PIGGY price moved");
        require(
            piggyPrice < piggyPriceOne, // price < $1
            "Treasury: piggyPrice not eligible for bond purchase"
        );

        require(_piggyAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _piggyAmount.mul(_rate).div(1e18);
        uint256 piggySupply = getPiggyCirculatingSupply();
        uint256 newBondSupply = IERC20(pbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= piggySupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(piggy).burnFrom(msg.sender, _piggyAmount);
        IBasisAsset(pbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_piggyAmount);
        _updatePiggyPrice();

        emit BoughtBonds(msg.sender, _piggyAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 piggyPrice = getPiggyPrice();
        require(piggyPrice == targetPrice, "Treasury: PIGGY price moved");
        require(
            piggyPrice > piggyPriceCeiling, // price > $1.01
            "Treasury: piggyPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _piggyAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(piggy).balanceOf(address(this)) >= _piggyAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _piggyAmount));

        IBasisAsset(pbond).burnFrom(msg.sender, _bondAmount);
        IERC20(piggy).safeTransfer(msg.sender, _piggyAmount);

        _updatePiggyPrice();

        emit RedeemedBonds(msg.sender, _piggyAmount, _bondAmount);
    }

    function _sendToMasonry(uint256 _amount) internal {
        IBasisAsset(piggy).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(piggy).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _communityFundSharedAmount = 0;
        if (communityFundSharedPercent > 0) {
            _communityFundSharedAmount = _amount.mul(communityFundSharedPercent).div(10000);
            IERC20(piggy).transfer(communityFund, _communityFundSharedAmount);
            emit CommunityFundFunded(now, _communityFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(piggy).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_communityFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(piggy).safeApprove(masonry, 0);
        IERC20(piggy).safeApprove(masonry, _amount);
        IMasonry(masonry).allocateSeigniorage(_amount);
        emit MasonryFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _piggySupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_piggySupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updatePiggyPrice();
        previousEpochPiggyPrice = getPiggyPrice();
        uint256 piggySupply = getPiggyCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToMasonry(piggySupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochPiggyPrice > piggyPriceCeiling) {
                // Expansion ($PIGGY Price > 1 $AVAX): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(pbond).totalSupply();
                uint256 _percentage = previousEpochPiggyPrice.sub(piggyPriceOne);
                uint256 _savedForBond;
                uint256 _savedForMasonry;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(piggySupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForMasonry = piggySupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = piggySupply.mul(_percentage).div(1e18);
                    _savedForMasonry = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForMasonry);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForMasonry > 0) {
                    _sendToMasonry(_savedForMasonry);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(piggy).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(piggy), "piggy");
        require(address(_token) != address(pbond), "bond");
        require(address(_token) != address(pshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function masonrySetOperator(address _operator) external onlyOperator {
        IMasonry(masonry).setOperator(_operator);
    }

    function masonrySetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IMasonry(masonry).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function masonryAllocateSeigniorage(uint256 amount) external onlyOperator {
        IMasonry(masonry).allocateSeigniorage(amount);
    }

    function masonryGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IMasonry(masonry).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
