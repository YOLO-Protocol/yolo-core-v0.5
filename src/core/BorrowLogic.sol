// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";

contract BorrowLogic {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant PRECISION_DIVISOR = 10000;

    // Storage variables accessed via delegatecall context from YoloHook
    IYoloOracle public yoloOracle;

    mapping(address => bool) public isYoloAsset;
    mapping(address => bool) public isWhiteListedCollateral;
    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs;
    mapping(address => CollateralConfiguration) public collateralConfigs;
    mapping(address => mapping(address => mapping(address => UserPosition))) public positions;
    mapping(address => UserPositionKey[]) public userPositionKeys;
    mapping(address => mapping(address => CollateralToYoloAssetConfiguration)) public pairConfigs;

    // Structs
    struct UserPosition {
        address borrower;
        address collateral;
        uint256 collateralSuppliedAmount;
        address yoloAsset;
        uint256 yoloAssetMinted;
        uint256 lastUpdatedTimeStamp;
        uint256 storedInterestRate;
        uint256 accruedInterest;
    }

    struct UserPositionKey {
        address collateral;
        address yoloAsset;
    }

    struct YoloAssetConfiguration {
        address yoloAssetAddress;
        uint256 maxMintableCap;
        uint256 maxFlashLoanableAmount;
    }

    struct CollateralConfiguration {
        address collateralAsset;
        uint256 maxSupplyCap;
    }

    struct CollateralToYoloAssetConfiguration {
        address collateral;
        address yoloAsset;
        uint256 interestRate;
        uint256 ltv;
        uint256 liquidationPenalty;
    }

    // Errors
    error YoloHook__NotYoloAsset();
    error YoloHook__CollateralNotRecognized();
    error YoloHook__InsufficientAmount();
    error YoloHook__InvalidPair();
    error YoloHook__ExceedsYoloAssetMintCap();
    error YoloHook__ExceedsCollateralCap();
    error YoloHook__CollateralPaused();
    error YoloHook__YoloAssetPaused();
    error YoloHook__NoDebt();
    error YoloHook__RepayExceedsDebt();
    error YoloHook__NotSolvent();
    error YoloHook__Solvent();
    error YoloHook__InvalidPosition();

    // Events
    event Borrowed(
        address indexed user,
        address indexed collateral,
        uint256 collateralAmount,
        address indexed yoloAsset,
        uint256 borrowAmount
    );

    event PositionPartiallyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 interestPaid,
        uint256 principalPaid,
        uint256 remainingPrincipal,
        uint256 remainingInterest
    );

    event PositionFullyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 collateralReturned
    );

    event Withdrawn(address indexed user, address indexed collateral, address indexed yoloAsset, uint256 amount);

    event Liquidated(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    function borrow(address _collateral, uint256 _collateralAmount, address _yoloAsset, uint256 _borrowAmount)
        external
    {
        // Validations
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (!isWhiteListedCollateral[_collateral]) revert YoloHook__CollateralNotRecognized();
        if (_borrowAmount == 0 || _collateralAmount == 0) revert YoloHook__InsufficientAmount();

        // Check pair configuration
        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        if (pairConfig.collateral == address(0)) revert YoloHook__InvalidPair();

        // Transfer collateral from user
        IERC20(_collateral).safeTransferFrom(msg.sender, address(this), _collateralAmount);

        // Get user position
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];

        // Handle new vs existing position
        if (position.borrower == address(0)) {
            // Initialize new position
            position.borrower = msg.sender;
            position.collateral = _collateral;
            position.yoloAsset = _yoloAsset;
            position.lastUpdatedTimeStamp = block.timestamp;
            position.storedInterestRate = pairConfig.interestRate;

            // Add to user's position keys
            userPositionKeys[msg.sender].push(UserPositionKey(_collateral, _yoloAsset));
        } else {
            // Update existing position with accrued interest
            _accrueInterest(position, pairConfig.interestRate);
        }

        // Update position amounts
        position.collateralSuppliedAmount += _collateralAmount;
        position.yoloAssetMinted += _borrowAmount;

        // Check solvency
        if (!_isSolvent(position, _collateral, _yoloAsset, pairConfig.ltv)) {
            revert YoloHook__NotSolvent();
        }

        // Check caps
        YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAsset];
        CollateralConfiguration storage colConfig = collateralConfigs[_collateral];

        if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

        if (IYoloSyntheticAsset(_yoloAsset).totalSupply() + _borrowAmount > assetConfig.maxMintableCap) {
            revert YoloHook__ExceedsYoloAssetMintCap();
        }
        if (colConfig.maxSupplyCap <= 0) revert YoloHook__CollateralPaused();

        if (IERC20(_collateral).balanceOf(address(this)) > colConfig.maxSupplyCap) {
            revert YoloHook__ExceedsCollateralCap();
        }

        // Mint yolo asset to user
        IYoloSyntheticAsset(_yoloAsset).mint(msg.sender, _borrowAmount);

        emit Borrowed(msg.sender, _collateral, _collateralAmount, _yoloAsset, _borrowAmount);
    }

    function repay(address _collateral, address _yoloAsset, uint256 _repayAmount, bool _returnCollateral)
        external
        returns (uint256 collateralToReturn)
    {
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];
        if (position.borrower == address(0)) revert YoloHook__InvalidPosition();

        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        _accrueInterest(position, pairConfig.interestRate);

        uint256 totalDebt = position.yoloAssetMinted + position.accruedInterest;
        if (totalDebt == 0) revert YoloHook__NoDebt();

        uint256 repayAmount = _repayAmount == 0 ? totalDebt : _repayAmount;
        if (repayAmount > totalDebt) revert YoloHook__RepayExceedsDebt();

        // Transfer tokens from user and burn
        IERC20(_yoloAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        IYoloSyntheticAsset(_yoloAsset).burn(address(this), repayAmount);

        // Split repayment between interest and principal
        uint256 interestPaid = repayAmount <= position.accruedInterest ? repayAmount : position.accruedInterest;
        position.accruedInterest -= interestPaid;
        uint256 principalPaid = repayAmount - interestPaid;
        position.yoloAssetMinted -= principalPaid;

        bool isFullyRepaid = (position.yoloAssetMinted == 0 && position.accruedInterest == 0);

        if (isFullyRepaid || _returnCollateral) {
            if (isFullyRepaid || position.yoloAssetMinted + position.accruedInterest == 0) {
                // Auto-return collateral if requested
                collateralToReturn = position.collateralSuppliedAmount;
                position.collateralSuppliedAmount = 0;

                // Check collateral cap after withdrawal
                CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
                if (colConfig.maxSupplyCap > 0) {
                    if (IERC20(_collateral).balanceOf(address(this)) > colConfig.maxSupplyCap) {
                        revert YoloHook__ExceedsCollateralCap();
                    }
                }

                // Return collateral to user
                IERC20(_collateral).safeTransfer(msg.sender, collateralToReturn);

                // Remove position from user's positions list
                _removeUserPositionKey(msg.sender, _collateral, _yoloAsset);
            }

            emit PositionFullyRepaid(msg.sender, _collateral, _yoloAsset, repayAmount, collateralToReturn);
        } else {
            emit PositionPartiallyRepaid(
                msg.sender,
                _collateral,
                _yoloAsset,
                repayAmount,
                interestPaid,
                principalPaid,
                position.yoloAssetMinted,
                position.accruedInterest
            );
        }
    }

    function withdraw(address _collateral, address _yoloAsset, uint256 _amount) external {
        UserPosition storage pos = positions[msg.sender][_collateral][_yoloAsset];
        if (pos.borrower == address(0)) revert YoloHook__InvalidPosition();
        if (_amount > pos.collateralSuppliedAmount) revert YoloHook__InsufficientAmount();

        CollateralToYoloAssetConfiguration storage cfg = pairConfigs[_collateral][_yoloAsset];
        _accrueInterest(pos, cfg.interestRate);

        uint256 newCollateralAmount = pos.collateralSuppliedAmount - _amount;

        // Check solvency after withdrawal
        if (pos.yoloAssetMinted + pos.accruedInterest > 0) {
            // Temporarily update for solvency check
            uint256 originalAmount = pos.collateralSuppliedAmount;
            pos.collateralSuppliedAmount = newCollateralAmount;

            bool isSolvent = _isSolvent(pos, _collateral, _yoloAsset, cfg.ltv);
            pos.collateralSuppliedAmount = originalAmount; // Restore

            if (!isSolvent) revert YoloHook__NotSolvent();
        }

        // Update position state
        pos.collateralSuppliedAmount = newCollateralAmount;

        // Transfer collateral to user
        IERC20(_collateral).safeTransfer(msg.sender, _amount);

        // Clean up empty positions
        if (newCollateralAmount == 0 && pos.yoloAssetMinted == 0 && pos.accruedInterest == 0) {
            _removeUserPositionKey(msg.sender, _collateral, _yoloAsset);
            delete positions[msg.sender][_collateral][_yoloAsset];
        }

        emit Withdrawn(msg.sender, _collateral, _yoloAsset, _amount);
    }

    function liquidate(address _user, address _collateral, address _yoloAsset, uint256 _repayAmount) external {
        UserPosition storage pos = positions[_user][_collateral][_yoloAsset];
        if (pos.borrower == address(0)) revert YoloHook__InvalidPosition();

        CollateralToYoloAssetConfiguration storage cfg = pairConfigs[_collateral][_yoloAsset];
        _accrueInterest(pos, cfg.interestRate);

        // Check if position is liquidatable
        if (_isSolvent(pos, _collateral, _yoloAsset, cfg.ltv)) revert YoloHook__Solvent();

        // Determine repay amount
        uint256 debt = pos.yoloAssetMinted + pos.accruedInterest;
        uint256 repayAmt = _repayAmount == 0 ? debt : _repayAmount;
        if (repayAmt > debt) revert YoloHook__RepayExceedsDebt();

        // Pull in and burn YoloAsset from liquidator
        IERC20(_yoloAsset).safeTransferFrom(msg.sender, address(this), repayAmt);
        IYoloSyntheticAsset(_yoloAsset).burn(address(this), repayAmt);

        // Split into interest vs principal
        uint256 interestPaid = repayAmt <= pos.accruedInterest ? repayAmt : pos.accruedInterest;
        pos.accruedInterest -= interestPaid;
        uint256 principalPaid = repayAmt - interestPaid;
        pos.yoloAssetMinted -= principalPaid;

        // Calculate collateral to seize
        uint256 collateralValueSeized =
            yoloOracle.getAssetPrice(_yoloAsset) * repayAmt / (10 ** IERC20Metadata(_yoloAsset).decimals());

        uint256 penalty = collateralValueSeized * cfg.liquidationPenalty / PRECISION_DIVISOR;
        uint256 totalValueToSeize = collateralValueSeized + penalty;

        uint256 collateralPrice = yoloOracle.getAssetPrice(_collateral);
        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 totalSeize = totalValueToSeize * (10 ** collateralDecimals) / collateralPrice;

        // Ensure we don't seize more than available
        if (totalSeize > pos.collateralSuppliedAmount) {
            totalSeize = pos.collateralSuppliedAmount;
        }

        pos.collateralSuppliedAmount -= totalSeize;

        // Clean up if position is fully liquidated
        if (pos.yoloAssetMinted == 0 && pos.accruedInterest == 0 && pos.collateralSuppliedAmount == 0) {
            delete positions[_user][_collateral][_yoloAsset];
            _removeUserPositionKey(_user, _collateral, _yoloAsset);
        }

        // Transfer seized collateral to liquidator
        IERC20(_collateral).safeTransfer(msg.sender, totalSeize);

        emit Liquidated(_user, _collateral, _yoloAsset, repayAmt, totalSeize);
    }

    // Internal helper functions
    function _accrueInterest(UserPosition storage _pos, uint256 _rate) internal {
        if (_pos.yoloAssetMinted == 0) {
            _pos.lastUpdatedTimeStamp = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - _pos.lastUpdatedTimeStamp;
        if (timeElapsed == 0) return;

        // Simple interest: interest = principal * rate * time / (365 days * precision)
        uint256 interest = (_pos.yoloAssetMinted * _rate * timeElapsed) / (365 days * PRECISION_DIVISOR);
        _pos.accruedInterest += interest;
        _pos.lastUpdatedTimeStamp = block.timestamp;
        _pos.storedInterestRate = _rate;
    }

    function _isSolvent(UserPosition storage _pos, address _collateral, address _yoloAsset, uint256 _ltv)
        internal
        view
        returns (bool)
    {
        if (_pos.yoloAssetMinted == 0 && _pos.accruedInterest == 0) return true;

        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        uint256 colVal =
            yoloOracle.getAssetPrice(_collateral) * _pos.collateralSuppliedAmount / (10 ** collateralDecimals);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * (_pos.yoloAssetMinted + _pos.accruedInterest)
            / (10 ** yoloAssetDecimals);

        return debtVal * PRECISION_DIVISOR <= colVal * _ltv;
    }

    function _removeUserPositionKey(address _user, address _collateral, address _yoloAsset) internal {
        UserPositionKey[] storage keys = userPositionKeys[_user];
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                // Swap with last element and pop
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
        }
    }
}
