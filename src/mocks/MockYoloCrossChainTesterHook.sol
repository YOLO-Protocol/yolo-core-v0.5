// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*---------- IMPORT INTERFACES ----------*/
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";

/**
 * @title   MockYoloCrossChainTesterHook
 * @author  0xyolodev.eth
 * @notice  Mock contract that simulates YoloHook's cross-chain functionality for testing
 * @dev     Simplified version of YoloHook focused only on cross-chain bridge functionality
 *          This contract can mint/burn YoloAssets and manage bridge registration
 */
contract MockYoloCrossChainTesterHook is Ownable {
    
    // ************************* //
    // *** CONTRACT VARIABLES *** //
    // ************************* //

    /*----- Asset Management -----*/
    mapping(address => bool) public isYoloAsset; // Mapping to check if an address is a Yolo asset
    address[] public yoloAssets; // Array of all created Yolo assets

    /*----- Cross-Chain Bridge Configuration -----*/
    address public registeredBridge; // Single registered bridge address

    // ***************//
    // *** EVENTS *** //
    // ************** //

    event YoloAssetCreated(address indexed asset, string name, string symbol, uint8 decimals);

    event BridgeRegistered(address indexed bridge);

    event CrossChainBurn(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed sender);

    event CrossChainMint(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed receiver);

    // ***************//
    // *** ERRORS *** //
    // ************** //
    
    error MockYoloHook__ZeroAddress();
    error MockYoloHook__NotYoloAsset();
    error MockYoloHook__NotBridge();
    error MockYoloHook__InsufficientAmount();

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     * @notice  Constructor to initialize the mock contract
     */
    constructor() Ownable(msg.sender) {}

    // *********************** //
    // *** ADMIN FUNCTIONS *** //
    // *********************** //

    /**
     * @notice  Create a new YoloAsset for testing
     * @param   _name      Name of the asset
     * @param   _symbol    Symbol of the asset
     * @param   _decimals  Decimals of the asset
     * @return  asset      Address of the created asset
     */
    function createNewYoloAsset(string calldata _name, string calldata _symbol, uint8 _decimals)
        external
        onlyOwner
        returns (address asset)
    {
        // Deploy the token
        YoloSyntheticAsset newAsset = new YoloSyntheticAsset(_name, _symbol, _decimals);
        asset = address(newAsset);

        // Register it
        isYoloAsset[asset] = true;
        yoloAssets.push(asset);

        emit YoloAssetCreated(asset, _name, _symbol, _decimals);
    }

    /**
     * @notice  Register a bridge contract that can mint/burn YoloAssets for cross-chain transfers
     * @param   _bridgeAddress  The address of the bridge contract to register
     */
    function registerBridge(address _bridgeAddress) external onlyOwner {
        if (_bridgeAddress == address(0)) revert MockYoloHook__ZeroAddress();

        registeredBridge = _bridgeAddress;

        emit BridgeRegistered(_bridgeAddress);
    }

    /**
     * @notice  Manually mint YoloAssets for testing (only owner)
     * @param   _yoloAsset  The YoloAsset to mint
     * @param   _amount     The amount to mint
     * @param   _receiver   The receiver of the minted tokens
     */
    function mintForTesting(address _yoloAsset, uint256 _amount, address _receiver) external onlyOwner {
        if (!isYoloAsset[_yoloAsset]) revert MockYoloHook__NotYoloAsset();
        if (_amount == 0) revert MockYoloHook__InsufficientAmount();
        if (_receiver == address(0)) revert MockYoloHook__ZeroAddress();

        IYoloSyntheticAsset(_yoloAsset).mint(_receiver, _amount);
    }

    // ******************************//
    // *** CROSS CHAIN FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Modifier to ensure only the registered bridge can call certain functions
     */
    modifier onlyBridge() {
        if (msg.sender != registeredBridge) revert MockYoloHook__NotBridge();
        _;
    }

    /**
     * @notice  Burn YoloAssets for cross-chain transfer (called by registered bridge)
     * @param   _yoloAsset  The YoloAsset to burn
     * @param   _amount     The amount to burn
     * @param   _sender     The original sender of the tokens
     */
    function crossChainBurn(address _yoloAsset, uint256 _amount, address _sender) external onlyBridge {
        if (!isYoloAsset[_yoloAsset]) revert MockYoloHook__NotYoloAsset();
        if (_amount == 0) revert MockYoloHook__InsufficientAmount();

        // Burn the tokens from the sender
        IYoloSyntheticAsset(_yoloAsset).burn(_sender, _amount);

        emit CrossChainBurn(msg.sender, _yoloAsset, _amount, _sender);
    }

    /**
     * @notice  Mint YoloAssets for cross-chain transfer (called by registered bridge)
     * @param   _yoloAsset  The YoloAsset to mint
     * @param   _amount     The amount to mint
     * @param   _receiver   The receiver of the minted tokens
     */
    function crossChainMint(address _yoloAsset, uint256 _amount, address _receiver) external onlyBridge {
        if (!isYoloAsset[_yoloAsset]) revert MockYoloHook__NotYoloAsset();
        if (_amount == 0) revert MockYoloHook__InsufficientAmount();
        if (_receiver == address(0)) revert MockYoloHook__ZeroAddress();

        // Mint the tokens to the receiver
        IYoloSyntheticAsset(_yoloAsset).mint(_receiver, _amount);

        emit CrossChainMint(msg.sender, _yoloAsset, _amount, _receiver);
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //

    /**
     * @notice  Get all created YoloAssets
     * @return  Array of YoloAsset addresses
     */
    function getAllYoloAssets() external view returns (address[] memory) {
        return yoloAssets;
    }

    /**
     * @notice  Get the total number of YoloAssets created
     * @return  uint256  Number of assets
     */
    function getYoloAssetCount() external view returns (uint256) {
        return yoloAssets.length;
    }

    /**
     * @notice  Get YoloAsset by index
     * @param   _index  Index in the array
     * @return  address YoloAsset address
     */
    function getYoloAssetByIndex(uint256 _index) external view returns (address) {
        require(_index < yoloAssets.length, "Index out of bounds");
        return yoloAssets[_index];
    }
}