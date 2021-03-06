// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPriceOracleGetter} from "./interfaces/IPriceOracleGetter.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {DataTypes} from "./types/DataTypes.sol";

/**
 * @title Strategy
 * @notice DAI Yearn Strategy
 * @author Sturdy
 **/
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    ILendingPoolAddressesProvider private constant PROVIDER = 
        ILendingPoolAddressesProvider(0xb7499a92fc36e9053a4324aFfae59d333635D9c3);
    
    string private lenderName;
    
    event Cloned(address indexed clone);

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault, string memory _name) BaseStrategy(_vault) {
        lenderName = _name;
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    function clone(address _vault, string memory _name) external returns (address) {
        return this.clone(_vault, msg.sender, msg.sender, msg.sender, _name);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        string memory _name
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _name);

        emit Cloned(newStrategy);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        string memory _name
    ) external {
        lenderName = _name;
        _initialize(_vault, _strategist, _rewards, _keeper);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategySturdyUSDC"
        return lenderName;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        DataTypes.ReserveData memory reserve = 
            ILendingPool(PROVIDER.getLendingPool()).getReserveData(address(want));
        
        return balanceOfWant() + IERC20(reserve.aTokenAddress).balanceOf(address(this));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        if (_debtOutstanding == 0)
            return (0, 0, _debtPayment);

        // Withdraw `want` token from Sturdy pool
        _removePosition(_debtOutstanding);

        _debtPayment = _debtOutstanding;
        uint256 availableWants = balanceOfWant();
        if (availableWants >= _debtOutstanding) {
            unchecked {
                _profit = availableWants - _debtOutstanding;   
            }
        } else {
            unchecked {
                _loss = _debtOutstanding - availableWants;   
            }
            _debtPayment = availableWants;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        uint256 availableWants = balanceOfWant();
        if(availableWants <= _debtOutstanding) {
            return;
        }

        unchecked {
            availableWants = availableWants - _debtOutstanding;   
        }

        // Deposit excess `want` token to Sturdy pool
        _addPosition(availableWants);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        // Withdraw `want` token from Sturdy pool
        _removePosition(_amountNeeded);

        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            unchecked {
                _loss = _amountNeeded - totalAssets;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // Withdraw `want` token from Sturdy pool
        _removePosition(type(uint256).max);

        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one

        // Withdraw `want` token from Sturdy pool
        _removePosition(type(uint256).max);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        uint256 wantDecimals = IERC20Metadata(address(want)).decimals();
        uint256 wantPriceInEth = 
            IPriceOracleGetter(PROVIDER.getPriceOracle()).getAssetPrice(address(want));
    
        return _amtInWei / wantPriceInEth * 10 ** wantDecimals;
    }

    /**
     * @dev withdraw `want` token from sturdy pool
     **/
    function _removePosition(uint256 amount) internal {
        DataTypes.ReserveData memory reserve = 
            ILendingPool(PROVIDER.getLendingPool()).getReserveData(address(want));
        uint256 wantBalance = IERC20(reserve.aTokenAddress).balanceOf(address(this));
        ILendingPool(PROVIDER.getLendingPool()).withdraw(
            address(want), 
            wantBalance > amount ? amount : wantBalance, 
            address(this)
        );
    }

    /**
     * @dev deposit `want` token to sturdy pool
     * @param _amountWant The amount of `want` token
     **/
    function _addPosition(uint256 _amountWant) internal {
        address pool = PROVIDER.getLendingPool();

        want.safeApprove(pool, _amountWant);
        ILendingPool(pool).deposit(address(want), _amountWant, address(this), 0);
    }
}
