// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "./YoloStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {InterestMath} from "../libraries/InterestMath.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/**
 * @title   SyntheticAssetLogic
 * @notice  Logic contract for synthetic asset operations (borrow, repay, withdraw, liquidate)
 * @dev     This contract is called via delegatecall from YoloHook, sharing its storage
 */
contract SyntheticAssetLogic is YoloStorage {
    using SafeERC20 for IERC20;

    /**
     * @notice Helper function for ceiling division (rounds up)
     * @dev Used to ensure protocol always rounds in its favor for user obligations
     * @param a Numerator
     * @param b Denominator
     * @return Result rounded up
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /**
     * @notice  Allow users to deposit collateral and mint yolo assets
     * @param   _yoloAsset          The yolo asset to mint
     * @param   _borrowAmount       The amount of yolo asset to mint
     * @param   _collateral         The collateral asset to deposit
     * @param   _collateralAmount   The amount of collateral to deposit
     */
    function borrow(address _yoloAsset, uint256 _borrowAmount, address _collateral, uint256 _collateralAmount)
        external
    {
        // Early validation checks with immediate returns
        if (_borrowAmount == 0 || _collateralAmount == 0) revert YoloHook__InsufficientAmount();
        if (_borrowAmount < MINIMUM_BORROW_AMOUNT) revert YoloHook__InsufficientAmount(); // Prevent dust loans
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (!isWhiteListedCollateral[_collateral]) revert YoloHook__CollateralNotRecognized();

        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        if (pairConfig.collateral == address(0)) revert YoloHook__InvalidPair();

        // Early pause checks
        YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAsset];
        if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

        CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
        if (colConfig.maxSupplyCap <= 0) revert YoloHook__CollateralPaused();

        // Transfer collateral first
        IERC20(_collateral).safeTransferFrom(msg.sender, address(this), _collateralAmount);

        // Update global liquidity index (lazy update)
        _updateGlobalLiquidityIndex(pairConfig, pairConfig.interestRate);

        // Handle position updates in a separate branch
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];
        if (position.borrower == address(0)) {
            // NEW POSITION
            _initializeNewPosition(position, msg.sender, _collateral, _yoloAsset, pairConfig.interestRate);

            // Set normalized principal and debt (cleaner accounting model)
            position.userLiquidityIndexRay = pairConfig.liquidityIndexRay;
            position.normalizedPrincipalRay = (_borrowAmount * RAY) / pairConfig.liquidityIndexRay;
            position.normalizedDebtRay = position.normalizedPrincipalRay;

            // Set expiration if pair is expirable
            if (pairConfig.isExpirable) {
                position.expiryTimestamp = block.timestamp + pairConfig.expirePeriod;
            } else {
                position.expiryTimestamp = 0;
            }
        } else {
            // EXISTING POSITION - bring to current state (round UP for user obligations)
            uint256 currentDebt =
                divUp(position.normalizedDebtRay * pairConfig.liquidityIndexRay, position.userLiquidityIndexRay);
            uint256 currentPrincipal =
                (position.normalizedPrincipalRay * position.userLiquidityIndexRay) / position.userLiquidityIndexRay;

            // Add new borrow to both principal and debt
            uint256 newNormalizedPrincipal = (_borrowAmount * RAY) / position.userLiquidityIndexRay;
            position.normalizedPrincipalRay += newNormalizedPrincipal;
            position.normalizedDebtRay = ((currentDebt + _borrowAmount) * RAY) / pairConfig.liquidityIndexRay;
            // keep user's original index for principal normalization
            position.lastUpdatedTimeStamp = block.timestamp;
        }

        // Update collateral amount
        position.collateralSuppliedAmount += _collateralAmount;

        // Final checks
        if (!_isSolvent(position, _collateral, _yoloAsset, pairConfig.ltv)) revert YoloHook__NotSolvent();
        if (IYoloSyntheticAsset(_yoloAsset).totalSupply() + _borrowAmount > assetConfig.maxMintableCap) {
            revert YoloHook__ExceedsYoloAssetMintCap();
        }
        if (IERC20(_collateral).balanceOf(address(this)) > colConfig.maxSupplyCap) {
            revert YoloHook__ExceedsCollateralCap();
        }

        // Mint and emit
        IYoloSyntheticAsset(_yoloAsset).mint(msg.sender, _borrowAmount);
        emit Borrowed(msg.sender, _collateral, _collateralAmount, _yoloAsset, _borrowAmount);
    }

    /**
     * @notice  Allows users to repay their borrowed YoloAssets
     * @param   _collateral         The collateral asset address
     * @param   _yoloAsset          The yolo asset address being repaid
     * @param   _repayAmount        The amount to repay (0 for full repayment)
     * @param   _claimCollateral    Whether to withdraw collateral after full repayment
     */
    function repay(address _collateral, address _yoloAsset, uint256 _repayAmount, bool _claimCollateral) external {
        UserPosition storage position = positions[msg.sender][_collateral][_yoloAsset];
        if (position.borrower != msg.sender) revert YoloHook__InvalidPosition();

        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];

        // Calculate effective index WITHOUT writing to storage first
        uint256 timeDelta = block.timestamp - pairConfig.lastUpdateTimestamp;
        uint256 effectiveIndexRay =
            InterestMath.calculateEffectiveIndex(pairConfig.liquidityIndexRay, position.storedInterestRate, timeDelta);

        // Calculate actual debt with the effective index (round UP for user obligations)
        uint256 actualDebt = divUp(position.normalizedDebtRay * effectiveIndexRay, RAY);
        if (actualDebt == 0) revert YoloHook__NoDebt();

        uint256 actualRepayAmount = _repayAmount == 0 ? actualDebt : _repayAmount;
        if (actualRepayAmount > actualDebt) revert YoloHook__RepayExceedsDebt();

        // NOW, update the global index in storage
        if (timeDelta > 0) {
            pairConfig.liquidityIndexRay = effectiveIndexRay;
            pairConfig.lastUpdateTimestamp = block.timestamp;
        }

        // Handle repayment in separate function
        (uint256 interestPaid, uint256 principalPaid) =
            _processRepayment(position, pairConfig, _yoloAsset, actualRepayAmount, actualDebt);

        // Check if fully repaid (with dust handling for new structure)
        if (position.normalizedPrincipalRay <= DUST_THRESHOLD && position.normalizedDebtRay <= DUST_THRESHOLD) {
            _handleFullRepayment(position, _collateral, _yoloAsset, actualRepayAmount, _claimCollateral);
        } else {
            // Calculate remaining debt for event (round UP)
            uint256 remainingDebt =
                divUp(position.normalizedDebtRay * pairConfig.liquidityIndexRay, position.userLiquidityIndexRay);
            uint256 remainingPrincipal =
                (position.normalizedPrincipalRay * pairConfig.liquidityIndexRay) / position.userLiquidityIndexRay;
            uint256 remainingInterest = remainingDebt - remainingPrincipal;

            emit PositionPartiallyRepaid(
                msg.sender,
                _collateral,
                _yoloAsset,
                actualRepayAmount,
                interestPaid,
                principalPaid,
                remainingPrincipal,
                remainingInterest
            );
        }
    }

    /**
     * @notice  Redeem up to `amount` of your collateral, provided your loan stays solvent
     * @param   _collateral    The collateral token address
     * @param   _yoloAsset     The YoloAsset token address
     * @param   _amount        How much collateral to withdraw
     */
    function withdraw(address _collateral, address _yoloAsset, uint256 _amount) external {
        UserPosition storage pos = positions[msg.sender][_collateral][_yoloAsset];
        if (pos.borrower != msg.sender) revert YoloHook__InvalidPosition();
        if (_amount == 0 || _amount > pos.collateralSuppliedAmount) revert YoloHook__InsufficientAmount();

        // Check if collateral is paused (optional, depends on your design intent)
        CollateralConfiguration storage colConfig = collateralConfigs[_collateral];
        if (colConfig.maxSupplyCap <= 0) revert YoloHook__CollateralPaused();

        // Update global liquidity index before checking solvency
        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        _updateGlobalLiquidityIndex(pairConfig, pos.storedInterestRate);

        // Calculate new collateral amount after withdrawal
        uint256 newCollateralAmount = pos.collateralSuppliedAmount - _amount;

        // Calculate current debt using the new accounting model (round UP for user obligations)
        uint256 currentDebt = divUp(pos.normalizedDebtRay * pairConfig.liquidityIndexRay, pos.userLiquidityIndexRay);

        // If there's remaining debt, ensure the post-withdraw position stays solvent
        if (currentDebt > 0) {
            // Temporarily reduce collateral for solvency check
            uint256 origCollateral = pos.collateralSuppliedAmount;
            pos.collateralSuppliedAmount = newCollateralAmount;

            // Check solvency using existing function
            bool isSolvent = _isSolvent(pos, _collateral, _yoloAsset, pairConfig.ltv);

            // Restore collateral amount
            pos.collateralSuppliedAmount = origCollateral;

            if (!isSolvent) revert YoloHook__NotSolvent();
        }

        // Update position state
        pos.collateralSuppliedAmount = newCollateralAmount;

        // Transfer collateral to user
        IERC20(_collateral).safeTransfer(msg.sender, _amount);

        // Clean up empty positions (treat tiny normalized values as cleared)
        if (
            newCollateralAmount == 0 && pos.normalizedDebtRay <= DUST_THRESHOLD
                && pos.normalizedPrincipalRay <= DUST_THRESHOLD
        ) {
            _removeUserPositionKey(msg.sender, _collateral, _yoloAsset);
            delete positions[msg.sender][_collateral][_yoloAsset];
        }

        emit Withdrawn(msg.sender, _collateral, _yoloAsset, _amount);
    }

    /**
     * @dev     Liquidate an under‐collateralized position
     * @param   _user        The borrower whose position is being liquidated
     * @param   _collateral  The collateral token address
     * @param   _yoloAsset   The YoloAsset token address
     * @param   _repayAmount How much of the borrower's debt to cover (0 == full debt)
     */
    function liquidate(address _user, address _collateral, address _yoloAsset, uint256 _repayAmount) external {
        // Early validation - all reverts first
        CollateralToYoloAssetConfiguration storage cfg = pairConfigs[_collateral][_yoloAsset];
        if (cfg.collateral == address(0)) revert YoloHook__InvalidPair();

        UserPosition storage pos = positions[_user][_collateral][_yoloAsset];
        if (pos.borrower == address(0)) revert YoloHook__InvalidPosition();

        // Update global index and check liquidation conditions
        _updateGlobalLiquidityIndex(cfg, pos.storedInterestRate);

        // Check if position is expired (immediate liquidation allowed)
        bool isExpired = cfg.isExpirable && pos.expiryTimestamp > 0 && block.timestamp >= pos.expiryTimestamp;

        if (!isExpired) {
            // Normal solvency check for non-expired positions
            if (_isSolvent(pos, _collateral, _yoloAsset, cfg.ltv)) revert YoloHook__Solvent();
        }
        // If expired, skip solvency check - immediate liquidation allowed

        // Calculate actual debt for repayment validation (round UP for user obligations)
        uint256 actualDebt = divUp(pos.normalizedDebtRay * cfg.liquidityIndexRay, RAY);
        uint256 actualRepayAmount = _repayAmount == 0 ? actualDebt : _repayAmount;
        if (actualRepayAmount > actualDebt) revert YoloHook__RepayExceedsDebt();

        // Execute liquidation after all validation
        _executeLiquidation(pos, cfg, _collateral, _yoloAsset, actualRepayAmount, _user, isExpired);
    }

    // ========================
    // INTERNAL HELPER FUNCTIONS
    // ========================

    function _initializeNewPosition(
        UserPosition storage position,
        address borrower,
        address collateral,
        address yoloAsset,
        uint256 interestRate
    ) private {
        position.borrower = borrower;
        position.collateral = collateral;
        position.yoloAsset = yoloAsset;
        position.lastUpdatedTimeStamp = block.timestamp;
        position.storedInterestRate = interestRate;

        UserPositionKey memory key = UserPositionKey({collateral: collateral, yoloAsset: yoloAsset});
        userPositionKeys[borrower].push(key);
    }

    function _processRepayment(
        UserPosition storage position,
        CollateralToYoloAssetConfiguration storage pairConfig,
        address yoloAsset,
        uint256 repayAmount,
        uint256 actualDebt
    ) private returns (uint256 interestPaid, uint256 principalPaid) {
        // Calculate current principal using the LATEST global index (round DOWN to favor protocol)
        uint256 currentPrincipal =
            (position.normalizedPrincipalRay * pairConfig.liquidityIndexRay) / position.userLiquidityIndexRay;
        uint256 interestAccrued = actualDebt - currentPrincipal;

        // Split repayment between interest and principal
        interestPaid = repayAmount < interestAccrued ? repayAmount : interestAccrued;
        principalPaid = repayAmount - interestPaid;

        if (principalPaid > currentPrincipal) {
            principalPaid = currentPrincipal;
        }

        uint256 totalRepaid = interestPaid + principalPaid;

        // Process payments
        if (interestPaid > 0) {
            IYoloSyntheticAsset(yoloAsset).burn(msg.sender, interestPaid);
            IYoloSyntheticAsset(yoloAsset).mint(treasury, interestPaid); // Interest to treasury
        }

        if (principalPaid > 0) {
            IYoloSyntheticAsset(yoloAsset).burn(msg.sender, principalPaid);
        }

        // Update normalized values
        uint256 newDebt = actualDebt - totalRepaid;
        uint256 newPrincipal = currentPrincipal - principalPaid;

        // Re-normalize debt and principal with the LATEST global index
        position.normalizedDebtRay = (newDebt * RAY) / pairConfig.liquidityIndexRay;
        position.normalizedPrincipalRay = (newPrincipal * RAY) / pairConfig.liquidityIndexRay;
        // Crucially, update the user's index to the current global one
        position.userLiquidityIndexRay = pairConfig.liquidityIndexRay;
        position.lastUpdatedTimeStamp = block.timestamp;
    }

    function _handleFullRepayment(
        UserPosition storage position,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        bool claimCollateral
    ) private {
        position.normalizedDebtRay = 0;
        position.normalizedPrincipalRay = 0;

        uint256 collateralToReturn = 0;
        if (claimCollateral && position.collateralSuppliedAmount > 0) {
            collateralToReturn = position.collateralSuppliedAmount;
            position.collateralSuppliedAmount = 0;

            IERC20(collateral).safeTransfer(msg.sender, collateralToReturn);
            _removeUserPositionKey(msg.sender, collateral, yoloAsset);
        }

        emit PositionFullyRepaid(msg.sender, collateral, yoloAsset, repayAmount, collateralToReturn);
    }

    function _executeLiquidation(
        UserPosition storage pos,
        CollateralToYoloAssetConfiguration storage cfg,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        address user,
        bool isExpired
    ) private {
        // Pull YoloAsset from liquidator and burn
        IERC20(yoloAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        IYoloSyntheticAsset(yoloAsset).burn(address(this), repayAmount);

        // Process debt reduction with compound interest
        (uint256 interestPaid, uint256 principalPaid) = _reduceLiquidatedDebt(pos, cfg, repayAmount);

        // Calculate collateral seizure
        uint256 totalSeize = _calculateCollateralSeizure(collateral, yoloAsset, repayAmount, cfg.liquidationPenalty);

        if (totalSeize > pos.collateralSuppliedAmount) revert YoloHook__InvalidSeizeAmount();

        // Update position
        pos.collateralSuppliedAmount -= totalSeize;

        // Clean up if fully liquidated
        _cleanupLiquidatedPosition(pos, user, collateral, yoloAsset);

        // Transfer seized collateral to liquidator
        IERC20(collateral).safeTransfer(msg.sender, totalSeize);

        emit Liquidated(user, collateral, yoloAsset, repayAmount, totalSeize, isExpired);
    }

    function _reduceLiquidatedDebt(
        UserPosition storage pos,
        CollateralToYoloAssetConfiguration storage cfg,
        uint256 repayAmount
    ) private returns (uint256 interestPaid, uint256 principalPaid) {
        // Calculate current actual debt (new accounting model)
        uint256 actualDebt = divUp(pos.normalizedDebtRay * cfg.liquidityIndexRay, RAY);
        uint256 currentPrincipal = (pos.normalizedPrincipalRay * pos.userLiquidityIndexRay) / RAY;
        uint256 interestAccrued = actualDebt - currentPrincipal;

        // Pay interest first
        interestPaid = repayAmount <= interestAccrued ? repayAmount : interestAccrued;
        principalPaid = repayAmount - interestPaid;

        if (principalPaid > currentPrincipal) {
            principalPaid = currentPrincipal;
        }

        // Update normalized values
        uint256 newActualDebt = actualDebt - (interestPaid + principalPaid);
        uint256 newPrincipal = currentPrincipal - principalPaid;

        pos.normalizedDebtRay = (newActualDebt * RAY) / cfg.liquidityIndexRay;
        pos.normalizedPrincipalRay = (newPrincipal * RAY) / pos.userLiquidityIndexRay;
        pos.lastUpdatedTimeStamp = block.timestamp;
    }

    function _calculateCollateralSeizure(
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        uint256 liquidationPenalty
    ) private view returns (uint256 totalSeize) {
        // Get oracle prices
        uint256 priceColl = yoloOracle.getAssetPrice(collateral);
        uint256 priceYol = yoloOracle.getAssetPrice(yoloAsset);

        // Calculate value repaid
        uint256 usdValueRepaid = repayAmount * priceYol;

        // Calculate raw collateral amount (round up)
        uint256 rawCollateralSeize = (usdValueRepaid + priceColl - 1) / priceColl;

        // Add liquidation bonus
        uint256 bonus = (rawCollateralSeize * liquidationPenalty) / PRECISION_DIVISOR;
        totalSeize = rawCollateralSeize + bonus;
    }

    function _cleanupLiquidatedPosition(UserPosition storage pos, address user, address collateral, address yoloAsset)
        private
    {
        // Treat dust amounts as fully liquidated
        if (pos.normalizedPrincipalRay <= DUST_THRESHOLD && pos.normalizedDebtRay <= DUST_THRESHOLD) {
            pos.normalizedPrincipalRay = 0;
            pos.normalizedDebtRay = 0;
        }

        // If position is fully cleared, delete it
        if (pos.normalizedPrincipalRay == 0 && pos.normalizedDebtRay == 0 && pos.collateralSuppliedAmount == 0) {
            delete positions[user][collateral][yoloAsset];
            _removeUserPositionKey(user, collateral, yoloAsset);
        }
    }

    function _updateGlobalLiquidityIndex(CollateralToYoloAssetConfiguration storage config, uint256 rate) internal {
        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        if (timeDelta == 0) return; // Already updated this block

        config.liquidityIndexRay = InterestMath.calculateLinearInterest(config.liquidityIndexRay, rate, timeDelta);
        config.lastUpdateTimestamp = block.timestamp;
    }

    function _isSolvent(UserPosition storage _pos, address _collateral, address _yoloAsset, uint256 _ltv)
        internal
        view
        returns (bool)
    {
        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        uint256 colVal =
            yoloOracle.getAssetPrice(_collateral) * _pos.collateralSuppliedAmount / (10 ** collateralDecimals);

        // Calculate actual debt using effective index (for view functions, no storage writes)
        CollateralToYoloAssetConfiguration storage config = pairConfigs[_collateral][_yoloAsset];
        uint256 effectiveIndexRay = InterestMath.calculateEffectiveIndex(
            config.liquidityIndexRay, _pos.storedInterestRate, block.timestamp - config.lastUpdateTimestamp
        );

        // Actual debt under effective index (round UP for user obligations)
        uint256 actualDebt = divUp(_pos.normalizedDebtRay * effectiveIndexRay, RAY);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * actualDebt / (10 ** yoloAssetDecimals);

        return debtVal * PRECISION_DIVISOR <= colVal * _ltv;
    }

    /**
     * @notice Renew an expired or soon-to-expire position
     * @param _collateral Collateral token address
     * @param _yoloAsset YoloAsset token address
     * @dev Pays accrued interest and extends expiration, updates to current interest rate
     */
    function renewPosition(address _collateral, address _yoloAsset) external {
        UserPosition storage pos = positions[msg.sender][_collateral][_yoloAsset];
        if (pos.borrower == address(0)) revert YoloHook__InvalidPosition();

        CollateralToYoloAssetConfiguration storage pairConfig = pairConfigs[_collateral][_yoloAsset];
        if (!pairConfig.isExpirable) revert YoloHook__PositionNotExpirable();
        if (pos.expiryTimestamp == 0) revert YoloHook__PositionNotExpirable();

        // Compute effective index WITHOUT storage writes (view-like computation)
        uint256 timeDelta = block.timestamp - pairConfig.lastUpdateTimestamp;
        uint256 effectiveIndexRay =
            InterestMath.calculateEffectiveIndex(pairConfig.liquidityIndexRay, pos.storedInterestRate, timeDelta);

        // Calculate accrued interest (round UP for user obligations)
        uint256 actualDebt = divUp(pos.normalizedDebtRay * effectiveIndexRay, RAY);
        uint256 currentPrincipal = (pos.normalizedPrincipalRay * pos.userLiquidityIndexRay) / RAY;
        uint256 interestAccrued = actualDebt - currentPrincipal;

        if (interestAccrued > 0) {
            // User must pay accrued interest to renew
            IERC20(_yoloAsset).safeTransferFrom(msg.sender, address(this), interestAccrued);
            IYoloSyntheticAsset(_yoloAsset).burn(address(this), interestAccrued);
            IYoloSyntheticAsset(_yoloAsset).mint(treasury, interestAccrued);
        }

        // NOW update global index with accrued time
        pairConfig.liquidityIndexRay = effectiveIndexRay;
        pairConfig.lastUpdateTimestamp = block.timestamp;

        // Update position to current state (principal unchanged, only debt updated)
        // Since we change userLiquidityIndexRay, re-normalize principal and debt to the new index
        pos.userLiquidityIndexRay = effectiveIndexRay;
        pos.normalizedPrincipalRay = (currentPrincipal * RAY) / pos.userLiquidityIndexRay;
        pos.normalizedDebtRay = pos.normalizedPrincipalRay; // debt reset to principal after interest payment
        pos.lastUpdatedTimeStamp = block.timestamp;

        // Update to NEW interest rate and extend expiry
        pos.storedInterestRate = pairConfig.interestRate;
        pos.expiryTimestamp = block.timestamp + pairConfig.expirePeriod;

        emit PositionRenewed(msg.sender, _collateral, _yoloAsset, pos.expiryTimestamp, interestAccrued);
    }

    function _removeUserPositionKey(address _user, address _collateral, address _yoloAsset) internal {
        UserPositionKey[] storage keys = userPositionKeys[_user];
        for (uint256 i = 0; i < keys.length;) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                // Swap with last element and pop
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }
}
