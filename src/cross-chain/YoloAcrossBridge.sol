// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*---------- IMPORT INTERFACES ----------*/
interface IYoloHook {
    function crossChainBurn(address _yoloAsset, uint256 _amount, address _sender) external;
    function crossChainMint(address _yoloAsset, uint256 _amount, address _receiver) external;
    function isYoloAsset(address _asset) external view returns (bool);
}

interface ISpokePool {
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    function getCurrentTime() external view returns (uint32);

    function depositQuoteTimeBuffer() external view returns (uint32);
}

/**
 * @title   YoloAcrossBridge
 * @author  0xyolodev.eth
 * @notice  Cross-chain bridge for YoloSyntheticAssets using Across Protocol
 * @dev     Enables native cross-chain transfers of YoloAssets via Across SpokePool
 *          Uses 0-amount deposits for pure messaging when bridging synthetic assets
 */
contract YoloAccrossBridge is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    uint32 private constant DEFAULT_FILL_DEADLINE_BUFFER = 4 hours; // 4 hours in seconds
    uint32 private constant DEFAULT_EXCLUSIVITY_DEADLINE = 60; // 1 minute exclusivity

    // ************************* //
    // *** CONTRACT VARIABLES *** //
    // ************************* //

    IYoloHook public immutable yoloHook;
    ISpokePool public immutable spokePool;
    uint256 public immutable currentChainId;

    // Mapping: chainId => yoloAsset => remoteYoloAsset
    mapping(uint256 => mapping(address => address)) public crossChainAssetMapping;

    // Mapping: chainId => bool (supported destination chains)
    mapping(uint256 => bool) public supportedChains;

    // Array of supported chain IDs for easy iteration
    uint256[] public supportedChainsList;

    // Mapping: chainId => bridge address on that chain
    mapping(uint256 => address) public destinationBridgeAddresses;

    // ***************//
    // *** EVENTS *** //
    // ************** //

    event CrossChainTransferInitiated(
        address indexed sender,
        address indexed recipient,
        address indexed yoloAsset,
        uint256 amount,
        uint256 destinationChainId,
        bytes32 depositId
    );

    event CrossChainTransferReceived(
        address indexed recipient, address indexed yoloAsset, uint256 amount, uint256 originChainId, address sender
    );

    event AssetMappingSet(uint256 indexed chainId, address indexed localAsset, address indexed remoteAsset);

    event ChainSupportUpdated(uint256 indexed chainId, bool supported);

    event DestinationBridgeAddressSet(uint256 indexed chainId, address indexed bridgeAddress);

    // ***************//
    // *** ERRORS *** //
    // ************** //

    error YoloAccrossBridge__ZeroAddress();
    error YoloAccrossBridge__ZeroAmount();
    error YoloAccrossBridge__NotYoloAsset();
    error YoloAccrossBridge__UnsupportedChain();
    error YoloAccrossBridge__NoAssetMapping();
    error YoloAccrossBridge__InsufficientBalance();
    error YoloAccrossBridge__InvalidMessage();
    error YoloAccrossBridge__UnauthorizedSender();
    error YoloAccrossBridge__NoBridgeAddress();

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     * @notice  Constructor to initialize the YoloAccrossBridge
     * @param   _yoloHook    Address of the YoloHook contract
     * @param   _spokePool   Address of the Across SpokePool contract
     * @param   _owner       Owner of the bridge contract
     */
    constructor(address _yoloHook, address _spokePool, address _owner) Ownable(_owner) {
        if (_yoloHook == address(0) || _spokePool == address(0)) {
            revert YoloAccrossBridge__ZeroAddress();
        }

        yoloHook = IYoloHook(_yoloHook);
        spokePool = ISpokePool(_spokePool);
        currentChainId = block.chainid;
    }

    // *********************** //
    // *** ADMIN FUNCTIONS *** //
    // *********************** //

    /**
     * @notice  Set the cross-chain asset mapping for a specific chain
     * @param   _chainId        Destination chain ID
     * @param   _localAsset     Local YoloAsset address
     * @param   _remoteAsset    Remote YoloAsset address on destination chain
     */
    function setAssetMapping(uint256 _chainId, address _localAsset, address _remoteAsset) external onlyOwner {
        if (_localAsset == address(0) || _remoteAsset == address(0)) {
            revert YoloAccrossBridge__ZeroAddress();
        }
        if (!yoloHook.isYoloAsset(_localAsset)) {
            revert YoloAccrossBridge__NotYoloAsset();
        }

        crossChainAssetMapping[_chainId][_localAsset] = _remoteAsset;

        emit AssetMappingSet(_chainId, _localAsset, _remoteAsset);
    }

    /**
     * @notice  Add or remove support for a destination chain
     * @param   _chainId    Chain ID to update
     * @param   _supported  Whether the chain is supported
     */
    function setSupportedChain(uint256 _chainId, bool _supported) external onlyOwner {
        if (_chainId == currentChainId) return; // Can't bridge to same chain

        bool currentlySupported = supportedChains[_chainId];
        supportedChains[_chainId] = _supported;

        if (_supported && !currentlySupported) {
            // Add to supported chains list
            supportedChainsList.push(_chainId);
        } else if (!_supported && currentlySupported) {
            // Remove from supported chains list
            for (uint256 i = 0; i < supportedChainsList.length; i++) {
                if (supportedChainsList[i] == _chainId) {
                    supportedChainsList[i] = supportedChainsList[supportedChainsList.length - 1];
                    supportedChainsList.pop();
                    break;
                }
            }
        }

        emit ChainSupportUpdated(_chainId, _supported);
    }

    /**
     * @notice  Set the bridge address for a destination chain
     * @param   _chainId        Destination chain ID
     * @param   _bridgeAddress  Bridge contract address on destination chain
     */
    function setDestinationBridgeAddress(uint256 _chainId, address _bridgeAddress) external onlyOwner {
        if (_bridgeAddress == address(0)) {
            revert YoloAccrossBridge__ZeroAddress();
        }
        if (_chainId == currentChainId) return; // Can't set bridge for same chain

        destinationBridgeAddresses[_chainId] = _bridgeAddress;

        emit DestinationBridgeAddressSet(_chainId, _bridgeAddress);
    }

    // ******************************//
    // *** USER FACING FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Bridge YoloAssets to another chain
     * @param   _yoloAsset          The YoloAsset to bridge
     * @param   _amount             Amount of YoloAsset to bridge
     * @param   _destinationChainId Destination chain ID
     * @param   _recipient          Recipient address on destination chain
     * @return  depositId           The deposit ID from Across
     */
    function crossChain(address _yoloAsset, uint256 _amount, uint256 _destinationChainId, address _recipient)
        external
        nonReentrant
        returns (bytes32 depositId)
    {
        return _crossChain(_yoloAsset, _amount, _destinationChainId, _recipient, msg.sender);
    }

    /**
     * @notice  Bridge YoloAssets to another chain on behalf of another user
     * @param   _yoloAsset          The YoloAsset to bridge
     * @param   _amount             Amount of YoloAsset to bridge
     * @param   _destinationChainId Destination chain ID
     * @param   _recipient          Recipient address on destination chain
     * @param   _sender             Original sender of the assets
     * @return  depositId           The deposit ID from Across
     */
    function crossChainFrom(
        address _yoloAsset,
        uint256 _amount,
        uint256 _destinationChainId,
        address _recipient,
        address _sender
    ) external nonReentrant returns (bytes32 depositId) {
        // Check allowance
        uint256 allowance = IERC20(_yoloAsset).allowance(_sender, msg.sender);
        if (allowance < _amount) {
            revert YoloAccrossBridge__InsufficientBalance();
        }

        return _crossChain(_yoloAsset, _amount, _destinationChainId, _recipient, _sender);
    }

    /**
     * @notice  Handle incoming cross-chain message from Across Protocol
     * @dev     This function is called by Across relayers when delivering messages
     * @param   _message        Encoded message containing transfer details
     */
    function handleV3AcrossMessage(
        address, // _tokenSent - not used for YoloAsset transfers
        uint256, // _amount - not used for YoloAsset transfers
        address, // _relayer - not used
        bytes memory _message
    ) external {
        // Only accept calls from the SpokePool
        if (msg.sender != address(spokePool)) {
            revert YoloAccrossBridge__UnauthorizedSender();
        }

        // Decode the message
        (address yoloAsset, uint256 amount, address recipient, uint256 originChainId, address originalSender) =
            abi.decode(_message, (address, uint256, address, uint256, address));

        // Validate the message
        if (yoloAsset == address(0) || recipient == address(0)) {
            revert YoloAccrossBridge__ZeroAddress();
        }
        if (amount == 0) {
            revert YoloAccrossBridge__ZeroAmount();
        }
        if (!yoloHook.isYoloAsset(yoloAsset)) {
            revert YoloAccrossBridge__NotYoloAsset();
        }

        // Mint the YoloAsset to the recipient
        yoloHook.crossChainMint(yoloAsset, amount, recipient);

        emit CrossChainTransferReceived(recipient, yoloAsset, amount, originChainId, originalSender);
    }

    // ***************************//
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //

    /**
     * @notice  Internal function to handle cross-chain transfers
     * @param   _yoloAsset          The YoloAsset to bridge
     * @param   _amount             Amount of YoloAsset to bridge
     * @param   _destinationChainId Destination chain ID
     * @param   _recipient          Recipient address on destination chain
     * @param   _sender             Original sender of the assets
     * @return  depositId           The deposit ID from Across
     */
    function _crossChain(
        address _yoloAsset,
        uint256 _amount,
        uint256 _destinationChainId,
        address _recipient,
        address _sender
    ) internal returns (bytes32 depositId) {
        // Validation
        if (_yoloAsset == address(0) || _recipient == address(0)) {
            revert YoloAccrossBridge__ZeroAddress();
        }
        if (_amount == 0) {
            revert YoloAccrossBridge__ZeroAmount();
        }
        if (!yoloHook.isYoloAsset(_yoloAsset)) {
            revert YoloAccrossBridge__NotYoloAsset();
        }
        if (!supportedChains[_destinationChainId]) {
            revert YoloAccrossBridge__UnsupportedChain();
        }

        // Check asset mapping exists for destination chain
        address remoteAsset = crossChainAssetMapping[_destinationChainId][_yoloAsset];
        if (remoteAsset == address(0)) {
            revert YoloAccrossBridge__NoAssetMapping();
        }

        // Check destination bridge address is set
        address destinationBridge = destinationBridgeAddresses[_destinationChainId];
        if (destinationBridge == address(0)) {
            revert YoloAccrossBridge__NoBridgeAddress();
        }

        // Check sender has sufficient balance
        if (IERC20(_yoloAsset).balanceOf(_sender) < _amount) {
            revert YoloAccrossBridge__InsufficientBalance();
        }

        // Burn the YoloAsset from sender
        yoloHook.crossChainBurn(_yoloAsset, _amount, _sender);

        // Prepare message for destination chain
        bytes memory message = abi.encode(
            remoteAsset, // yoloAsset on destination chain
            _amount, // amount to mint
            _recipient, // recipient on destination chain
            currentChainId, // origin chain ID
            _sender // original sender
        );

        // Get current time and calculate deadlines
        uint32 currentTime = spokePool.getCurrentTime();
        uint32 quoteTimestamp = currentTime;
        uint32 fillDeadline = currentTime + DEFAULT_FILL_DEADLINE_BUFFER;
        uint32 exclusivityDeadline = 0; // No exclusivity for cross-chain messaging

        // Create deposit ID (simplified)
        depositId = keccak256(
            abi.encodePacked(
                _sender, _recipient, _yoloAsset, _amount, _destinationChainId, block.timestamp, block.number
            )
        );

        // Send cross-chain message via Across (0-amount deposit)
        spokePool.depositV3(
            _sender, // depositor
            destinationBridge, // recipient (bridge on destination chain)
            address(0), // inputToken (none for messages)
            address(0), // outputToken (none for messages)
            0, // inputAmount (0 for messages)
            0, // outputAmount (0 for messages)
            _destinationChainId, // destinationChainId
            address(0), // exclusiveRelayer (none)
            quoteTimestamp, // quoteTimestamp
            fillDeadline, // fillDeadline
            exclusivityDeadline, // exclusivityDeadline
            message // message containing transfer data
        );

        emit CrossChainTransferInitiated(_sender, _recipient, _yoloAsset, _amount, _destinationChainId, depositId);
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //

    /**
     * @notice  Get the remote asset address for a local asset on a specific chain
     * @param   _chainId     Destination chain ID
     * @param   _localAsset  Local YoloAsset address
     * @return  remoteAsset  Remote YoloAsset address
     */
    function getRemoteAsset(uint256 _chainId, address _localAsset) external view returns (address) {
        return crossChainAssetMapping[_chainId][_localAsset];
    }

    /**
     * @notice  Get all supported destination chains
     * @return  Array of supported chain IDs
     */
    function getSupportedChains() external view returns (uint256[] memory) {
        return supportedChainsList;
    }

    /**
     * @notice  Check if a chain is supported for bridging
     * @param   _chainId  Chain ID to check
     * @return  bool      True if chain is supported
     */
    function isChainSupported(uint256 _chainId) external view returns (bool) {
        return supportedChains[_chainId];
    }

    /**
     * @notice  Get the current chain ID
     * @return  uint256   Current chain ID
     */
    function getCurrentChainId() external view returns (uint256) {
        return currentChainId;
    }

    /**
     * @notice  Get the bridge address for a destination chain
     * @param   _chainId        Destination chain ID
     * @return  bridgeAddress   Bridge contract address on destination chain
     */
    function getDestinationBridgeAddress(uint256 _chainId) external view returns (address) {
        return destinationBridgeAddresses[_chainId];
    }
}
