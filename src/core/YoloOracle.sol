// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/*---------- IMPORT INTERFACES ----------*/
import "@yolo/contracts/interfaces/IPriceOracle.sol";
import "@yolo/contracts/interfaces/IYoloHook.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title   YoloOracle
 * @author  0xyolodev.eth
 * @notice  Serves as the unified aggregator for all price feed sources. It provides pricing data for
 *          collateral assets and Yolo synthetic assets, and acts as the reference source for monitoring
 *          health factors and triggering liquidations.
 */
contract YoloOracle is Ownable {
    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //
    IYoloHook public yoloHook;
    address public anchor;
    mapping(address => IPriceOracle) private assetToPriceSource;

    // ************** //
    // *** EVENTS *** //
    // ************** //
    event HookSet(address indexed yoloHook);
    event AssetSourceUpdated(address indexed asset, address indexed source);
    event AnchorSet(address indexed anchor);

    // *****************//
    // *** ERRORS *** //
    // **************** //
    error ParamsLengthMismatch();
    error PriceSourceCannotBeZero();
    error CallerNotOwnerOrHook();
    error AnchorAlreadySet();
    error UnsupportedAsset();

    // *****************//
    // *** MODIFIER *** //
    // **************** //
    /**
     * @notice  Ensure only owner or the hook can call the function.
     * @dev     Hook may need to call this contract on occations such as setting price sources
     *          while creating a new Yolo synthetic asset.
     */
    modifier onlyOwnerOrHook() {
        if (msg.sender != owner() && msg.sender != address(yoloHook)) revert CallerNotOwnerOrHook();
        _;
    }

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //
    /**
     * @notice  Constructor to setup YoloOracle with initial assets and their corresponding price sources.
     * @param   _assets             Array of assets to be initialized with price sources
     * @param   _sources            Array of price sources corresponding to the assets
     */
    constructor(address[] memory _assets, address[] memory _sources) Ownable(msg.sender) {
        _setAssetsSources(_assets, _sources);
    }

    // ******************//
    // *** FUNCTIONS *** //
    // ***************** //
    /**
     * @notice  Gets the price of a single asset
     * @param   _asset           Address of the asset for which the price is requested
     */
    function getAssetPrice(address _asset) public view returns (uint256) {
        // If anchor is set and the asset is the anchor, return a fixed price
        if (anchor != address(0) && _asset == anchor) return 1e8;
        IPriceOracle source = assetToPriceSource[_asset];
        if (source == IPriceOracle(address(0))) revert UnsupportedAsset();
        int256 price = source.latestAnswer();
        if (price > 0) return uint256(price);
        else return 0;
    }
    /**
     * @notice  Gets the prices of multiple assets in batch.
     * @param   _assets         Array of asset addresses for which the prices are requested
     */

    function getAssetsPrices(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            prices[i] = getAssetPrice(_assets[i]);
        }
        return prices;
    }

    // ************************//
    // *** ADMIN FUNCTIONS *** //
    // *********************** //
    /**
     * @notice  Sets the price sources for the given assets in batch.
     * @param   _assets             Array of assets to be initialized with price sources
     * @param   _sources            Array of price sources corresponding to the assets
     */
    function setAssetSources(address[] calldata _assets, address[] calldata _sources) external onlyOwnerOrHook {
        _setAssetsSources(_assets, _sources);
    }

    /**
     * @notice  Sets the hook address.
     * @dev     This function can only be called once. Make sure to set the hook proxy
     *          address and not the implementation address.
     * @param   _hook   Address of the YoloHook proxy contract to be set.
     */
    function setHook(address _hook) external onlyOwner {
        yoloHook = IYoloHook(_hook);
        emit HookSet(_hook);
    }

    /**
     * @notice  Sets the address of the anchor asset.
     * @dev     This function can only be called once.
     * @param   _anchor   Address of the anchor asset (Yolo USD).
     */
    function setAnchor(address _anchor) external onlyOwner {
        if (anchor != address(0)) revert AnchorAlreadySet();
        anchor = _anchor;
        emit AnchorSet(_anchor);
    }

    // **********************************//
    // *** INTERNAL HELPER FUNCTIONS *** //
    // ********************************* //
    function _setAssetsSources(address[] memory _assets, address[] memory _sources) internal {
        // Guard clause: ensure that the lengths of assets and sources arrays match
        if (_assets.length != _sources.length) revert ParamsLengthMismatch();

        // Iterate
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_sources[i] == address(0)) revert PriceSourceCannotBeZero();
            assetToPriceSource[_assets[i]] = IPriceOracle(_sources[i]);
            emit AssetSourceUpdated(_assets[i], _sources[i]);
        }
    }
}
