// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*---------- IMPORT CHAINLINK CCIP ----------*/
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";

/*---------- IMPORT INTERFACES ----------*/
interface IYoloHook {
    function crossChainBurn(address _yoloAsset, uint256 _amount, address _sender) external;
    function crossChainMint(address _yoloAsset, uint256 _amount, address _receiver) external;
    function isYoloAsset(address _asset) external view returns (bool);
}

/**
 * @title   YoloCCIPBridge
 * @author  0xyolodev.eth
 * @notice  Cross-chain bridge for YoloSyntheticAssets using Chainlink CCIP
 * @dev     Enables native cross-chain transfers of YoloAssets via CCIP messaging
 *          Burns assets on source chain and mints equivalent assets on destination chain
 */
contract YoloCCIPBridge is CCIPReceiver, OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    uint256 private constant GAS_LIMIT = 200_000; // Gas limit for destination execution

    // ************************* //
    // *** CONTRACT VARIABLES *** //
    // ************************* //

    IRouterClient public immutable router;
    IYoloHook public immutable yoloHook;
    uint64 public immutable currentChainSelector;

    /*----- Cross-Chain Asset Mapping -----*/
    // chainSelector => localAsset => remoteAsset
    mapping(uint64 => mapping(address => address)) public crossChainAssetMapping;

    /*----- Supported Chains -----*/
    mapping(uint64 => bool) public supportedChains;
    uint64[] public supportedChainsList;

    /*----- Cross-Chain Fees -----*/
    // Note: Fees are calculated dynamically by CCIP router

    // ***************//
    // *** EVENTS *** //
    // ************** //

    event CrossChainTransferInitiated(
        address indexed sender,
        address indexed recipient,
        address indexed yoloAsset,
        uint256 amount,
        uint64 destinationChainSelector,
        bytes32 messageId
    );

    event CrossChainTransferReceived(
        address indexed recipient, address indexed yoloAsset, uint256 amount, uint64 sourceChainSelector, address sender
    );

    event AssetMappingSet(uint64 indexed chainSelector, address indexed localAsset, address indexed remoteAsset);

    event ChainSupportUpdated(uint64 indexed chainSelector, bool supported);

    // Note: Chain fees are handled dynamically by CCIP router

    // ***************//
    // *** ERRORS *** //
    // ************** //

    error YoloCCIPBridge__ZeroAddress();
    error YoloCCIPBridge__ZeroAmount();
    error YoloCCIPBridge__NotYoloAsset();
    error YoloCCIPBridge__UnsupportedChain();
    error YoloCCIPBridge__NoAssetMapping();
    error YoloCCIPBridge__InsufficientBalance();
    error YoloCCIPBridge__InsufficientFee();
    error YoloCCIPBridge__InvalidMessage();
    error YoloCCIPBridge__OnlyRouter();

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     * @notice  Constructor to initialize the YoloCCIPBridge
     * @param   _router             Address of the CCIP Router contract
     * @param   _yoloHook          Address of the YoloHook contract
     * @param   _currentChainSelector  Current chain's CCIP selector
     */
    constructor(address _router, address _yoloHook, uint64 _currentChainSelector)
        CCIPReceiver(_router)
        OwnerIsCreator()
    {
        if (_router == address(0) || _yoloHook == address(0)) {
            revert YoloCCIPBridge__ZeroAddress();
        }

        router = IRouterClient(_router);
        yoloHook = IYoloHook(_yoloHook);
        currentChainSelector = _currentChainSelector;
    }

    // *********************** //
    // *** ADMIN FUNCTIONS *** //
    // *********************** //

    /**
     * @notice  Set the cross-chain asset mapping for a specific chain
     * @param   _chainSelector  Destination chain selector
     * @param   _localAsset     Local YoloAsset address
     * @param   _remoteAsset    Remote YoloAsset address on destination chain
     */
    function setAssetMapping(uint64 _chainSelector, address _localAsset, address _remoteAsset) external onlyOwner {
        if (_localAsset == address(0) || _remoteAsset == address(0)) {
            revert YoloCCIPBridge__ZeroAddress();
        }
        if (!yoloHook.isYoloAsset(_localAsset)) {
            revert YoloCCIPBridge__NotYoloAsset();
        }

        crossChainAssetMapping[_chainSelector][_localAsset] = _remoteAsset;

        emit AssetMappingSet(_chainSelector, _localAsset, _remoteAsset);
    }

    /**
     * @notice  Add or remove support for a destination chain
     * @param   _chainSelector  Chain selector to update
     * @param   _supported      Whether the chain is supported
     */
    function setSupportedChain(uint64 _chainSelector, bool _supported) external onlyOwner {
        if (_chainSelector == currentChainSelector) return; // Can't bridge to same chain

        bool currentlySupported = supportedChains[_chainSelector];
        supportedChains[_chainSelector] = _supported;

        if (_supported && !currentlySupported) {
            // Add to supported chains list
            supportedChainsList.push(_chainSelector);
        } else if (!_supported && currentlySupported) {
            // Remove from supported chains list
            for (uint256 i = 0; i < supportedChainsList.length; i++) {
                if (supportedChainsList[i] == _chainSelector) {
                    supportedChainsList[i] = supportedChainsList[supportedChainsList.length - 1];
                    supportedChainsList.pop();
                    break;
                }
            }
        }

        emit ChainSupportUpdated(_chainSelector, _supported);
    }

    // Note: Chain fees are calculated dynamically by CCIP router

    /**
     * @notice  Withdraw collected fees from the contract
     * @param   _to     Address to send fees to
     * @param   _amount Amount to withdraw (0 for all)
     */
    function withdrawFees(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert YoloCCIPBridge__ZeroAddress();

        uint256 balance = address(this).balance;
        uint256 withdrawAmount = _amount == 0 ? balance : _amount;

        if (withdrawAmount > balance) withdrawAmount = balance;

        payable(_to).transfer(withdrawAmount);
    }

    // ******************************//
    // *** USER FACING FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Bridge YoloAssets to another chain
     * @param   _yoloAsset              The YoloAsset to bridge
     * @param   _amount                 Amount of YoloAsset to bridge
     * @param   _destinationChainSelector Destination chain selector
     * @param   _recipient              Recipient address on destination chain
     * @return  messageId               The CCIP message ID
     */
    function crossChain(address _yoloAsset, uint256 _amount, uint64 _destinationChainSelector, address _recipient)
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        return _crossChain(_yoloAsset, _amount, _destinationChainSelector, _recipient, msg.sender);
    }

    /**
     * @notice  Bridge YoloAssets to another chain on behalf of another user
     * @param   _yoloAsset              The YoloAsset to bridge
     * @param   _amount                 Amount of YoloAsset to bridge
     * @param   _destinationChainSelector Destination chain selector
     * @param   _recipient              Recipient address on destination chain
     * @param   _sender                 Original sender of the assets
     * @return  messageId               The CCIP message ID
     */
    function crossChainFrom(
        address _yoloAsset,
        uint256 _amount,
        uint64 _destinationChainSelector,
        address _recipient,
        address _sender
    ) external payable nonReentrant returns (bytes32 messageId) {
        // Check allowance
        uint256 allowance = IERC20(_yoloAsset).allowance(_sender, msg.sender);
        if (allowance < _amount) {
            revert YoloCCIPBridge__InsufficientBalance();
        }

        return _crossChain(_yoloAsset, _amount, _destinationChainSelector, _recipient, _sender);
    }

    /**
     * @notice  Get the fee required to bridge to a specific chain
     * @param   _chainSelector  Destination chain selector
     * @param   _yoloAsset     YoloAsset to bridge
     * @param   _amount        Amount to bridge
     * @return  fee            Required fee in native token
     */
    function getFee(uint64 _chainSelector, address _yoloAsset, uint256 _amount) external view returns (uint256 fee) {
        // Create message for fee calculation
        bytes memory message = abi.encode(_yoloAsset, _amount, address(0), currentChainSelector, address(0));

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: message,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: GAS_LIMIT})),
            feeToken: address(0) // Native token
        });

        fee = router.getFee(_chainSelector, evm2AnyMessage);
    }

    // ****************************//
    // *** CCIP HOOK FUNCTIONS *** //
    // *************************** //

    /**
     * @notice  Handle incoming CCIP messages
     * @dev     Called by CCIP when a message is received from another chain
     * @param   message  The CCIP message containing transfer details
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Router validation is handled by CCIPReceiver base contract

        // Decode the message
        (address yoloAsset, uint256 amount, address recipient, uint64 sourceChainSelector, address originalSender) =
            abi.decode(message.data, (address, uint256, address, uint64, address));

        // Validate the message
        if (yoloAsset == address(0) || recipient == address(0)) {
            revert YoloCCIPBridge__ZeroAddress();
        }
        if (amount == 0) {
            revert YoloCCIPBridge__ZeroAmount();
        }
        if (!yoloHook.isYoloAsset(yoloAsset)) {
            revert YoloCCIPBridge__NotYoloAsset();
        }

        // Mint the YoloAsset to the recipient
        yoloHook.crossChainMint(yoloAsset, amount, recipient);

        emit CrossChainTransferReceived(recipient, yoloAsset, amount, sourceChainSelector, originalSender);
    }

    // ***************************//
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //

    /**
     * @notice  Internal function to handle cross-chain transfers
     * @param   _yoloAsset              The YoloAsset to bridge
     * @param   _amount                 Amount of YoloAsset to bridge
     * @param   _destinationChainSelector Destination chain selector
     * @param   _recipient              Recipient address on destination chain
     * @param   _sender                 Original sender of the assets
     * @return  messageId               The CCIP message ID
     */
    function _crossChain(
        address _yoloAsset,
        uint256 _amount,
        uint64 _destinationChainSelector,
        address _recipient,
        address _sender
    ) internal returns (bytes32 messageId) {
        // Validation
        if (_yoloAsset == address(0) || _recipient == address(0)) {
            revert YoloCCIPBridge__ZeroAddress();
        }
        if (_amount == 0) {
            revert YoloCCIPBridge__ZeroAmount();
        }
        if (!yoloHook.isYoloAsset(_yoloAsset)) {
            revert YoloCCIPBridge__NotYoloAsset();
        }
        if (!supportedChains[_destinationChainSelector]) {
            revert YoloCCIPBridge__UnsupportedChain();
        }

        // Check asset mapping exists for destination chain
        address remoteAsset = crossChainAssetMapping[_destinationChainSelector][_yoloAsset];
        if (remoteAsset == address(0)) {
            revert YoloCCIPBridge__NoAssetMapping();
        }

        // Check sender has sufficient balance
        if (IERC20(_yoloAsset).balanceOf(_sender) < _amount) {
            revert YoloCCIPBridge__InsufficientBalance();
        }

        // Prepare message for destination chain
        bytes memory message = abi.encode(
            remoteAsset, // yoloAsset on destination chain
            _amount, // amount to mint
            _recipient, // recipient on destination chain
            currentChainSelector, // source chain selector
            _sender // original sender
        );

        // Create CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)), // This bridge contract on destination chain
            data: message,
            tokenAmounts: new Client.EVMTokenAmount[](0), // No tokens, just message
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: GAS_LIMIT})),
            feeToken: address(0) // Use native token for fees
        });

        // Calculate required fee
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        // Check sufficient fee provided
        if (msg.value < fees) {
            revert YoloCCIPBridge__InsufficientFee();
        }

        // Burn the YoloAsset from sender (must be done before sending message)
        yoloHook.crossChainBurn(_yoloAsset, _amount, _sender);

        // Send CCIP message
        messageId = router.ccipSend{value: fees}(_destinationChainSelector, evm2AnyMessage);

        emit CrossChainTransferInitiated(_sender, _recipient, _yoloAsset, _amount, _destinationChainSelector, messageId);
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //

    /**
     * @notice  Get the remote asset address for a local asset on a specific chain
     * @param   _chainSelector  Destination chain selector
     * @param   _localAsset     Local YoloAsset address
     * @return  remoteAsset     Remote YoloAsset address
     */
    function getRemoteAsset(uint64 _chainSelector, address _localAsset) external view returns (address) {
        return crossChainAssetMapping[_chainSelector][_localAsset];
    }

    /**
     * @notice  Get all supported destination chains
     * @return  Array of supported chain selectors
     */
    function getSupportedChains() external view returns (uint64[] memory) {
        return supportedChainsList;
    }

    /**
     * @notice  Check if a chain is supported for bridging
     * @param   _chainSelector  Chain selector to check
     * @return  bool           True if chain is supported
     */
    function isChainSupported(uint64 _chainSelector) external view returns (bool) {
        return supportedChains[_chainSelector];
    }

    /**
     * @notice  Get the current chain selector
     * @return  uint64         Current chain selector
     */
    function getCurrentChainSelector() external view returns (uint64) {
        return currentChainSelector;
    }

    // Note: getRouter() is inherited from CCIPReceiver

    // ************************//
    // *** RECEIVE FUNCTION *** //
    // *********************** //

    /**
     * @notice  Receive function to accept native token for fees
     */
    receive() external payable {}
}
