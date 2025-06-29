// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title ChainlinkFunctionsHybridOracle
 * @author 0xyolodev.eth
 * @notice Hybrid oracle that combines Chainlink Functions (for on-demand API calls) with
 *         traditional Chainlink Price Feeds for maximum precision and reliability.
 *         Returns the most recent price between the two sources based on timestamp.
 */
contract ChainlinkFunctionsHybridOracle is FunctionsClient, ConfirmedOwner, IPriceOracle {
    using FunctionsRequest for FunctionsRequest.Request;

    // ********************//
    // *** STATE VARS *** //
    // ****************** //
    
    // Chainlink Functions configuration
    bytes32 public donId;
    uint64 public subscriptionId;
    uint32 public gasLimit;
    string public apiSource;
    
    // Traditional Chainlink Price Feed
    AggregatorV3Interface public immutable priceFeed;
    
    // Hybrid oracle state
    int256 public functionsLatestAnswer;
    uint256 public functionsLatestTimestamp;
    uint256 public functionsLatestRound;
    
    // Request tracking
    mapping(bytes32 => bool) public validRequestIds;
    bytes32 public lastRequestId;
    
    // Emergency controls
    bool public functionsEnabled = true;
    bool public emergencyMode = false;
    
    // ************** //
    // *** EVENTS *** //
    // ************** //
    event FunctionsResponse(bytes32 indexed requestId, int256 price, uint256 timestamp);
    event PullRequested(bytes32 indexed requestId, address indexed requester);
    event FunctionsToggled(bool enabled);
    event EmergencyModeToggled(bool enabled);
    event ConfigurationUpdated(bytes32 donId, uint64 subscriptionId, uint32 gasLimit);
    event ApiSourceUpdated(string newSource);
    
    // *************** //
    // *** ERRORS *** //
    // *************** //
    error UnexpectedRequestID(bytes32 requestId);
    error EmptyResponse();
    error FunctionsDisabled();
    error EmergencyModeActive();
    error InvalidConfiguration();

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //
    /**
     * @param _router Chainlink Functions router address
     * @param _priceFeed Traditional Chainlink price feed address
     * @param _apiSource JavaScript source code for API call
     * @param _donId DON ID for Chainlink Functions
     * @param _subscriptionId Subscription ID for Chainlink Functions
     * @param _gasLimit Gas limit for Functions request
     */
    constructor(
        address _router,
        address _priceFeed,
        string memory _apiSource,
        bytes32 _donId,
        uint64 _subscriptionId,
        uint32 _gasLimit
    ) FunctionsClient(_router) ConfirmedOwner(msg.sender) {
        priceFeed = AggregatorV3Interface(_priceFeed);
        apiSource = _apiSource;
        donId = _donId;
        subscriptionId = _subscriptionId;
        gasLimit = _gasLimit;
        
        // Initialize Functions data with current price feed data
        (, int256 price, , uint256 timestamp, ) = priceFeed.latestRoundData();
        functionsLatestAnswer = price;
        functionsLatestTimestamp = timestamp;
        functionsLatestRound = 1;
    }

    // **********************//
    // *** PUBLIC FUNCTIONS ***//
    // ******************** //
    
    /**
     * @notice Pull latest price from off-chain API via Chainlink Functions
     * @dev Anyone can call this to trigger a price update
     */
    function pullPrice() external returns (bytes32 requestId) {
        if (!functionsEnabled) revert FunctionsDisabled();
        if (emergencyMode) revert EmergencyModeActive();
        
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(apiSource);
        
        requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donId
        );
        
        validRequestIds[requestId] = true;
        lastRequestId = requestId;
        
        emit PullRequested(requestId, msg.sender);
        return requestId;
    }
    
    /**
     * @notice Returns the latest answer from the most recent source (Functions vs Price Feed)
     * @return Latest price with highest precision
     */
    function latestAnswer() external view override returns (int256) {
        if (emergencyMode) {
            return priceFeed.latestAnswer();
        }
        
        (, int256 feedPrice, , uint256 feedTimestamp, ) = priceFeed.latestRoundData();
        
        // Return the price from the most recent timestamp
        if (functionsLatestTimestamp > feedTimestamp && functionsEnabled) {
            return functionsLatestAnswer;
        } else {
            return feedPrice;
        }
    }
    
    /**
     * @notice Returns the timestamp of the latest answer
     * @return Timestamp of the most recent price update
     */
    function latestTimestamp() external view override returns (uint256) {
        if (emergencyMode) {
            (, , , uint256 timestamp, ) = priceFeed.latestRoundData();
            return timestamp;
        }
        
        (, , , uint256 feedTimestamp, ) = priceFeed.latestRoundData();
        
        // Return the most recent timestamp
        if (functionsLatestTimestamp > feedTimestamp && functionsEnabled) {
            return functionsLatestTimestamp;
        } else {
            return feedTimestamp;
        }
    }
    
    /**
     * @notice Returns the latest round ID
     * @return Round ID (combines both sources)
     */
    function latestRound() external view override returns (uint256) {
        uint256 feedRound = priceFeed.latestRound();
        return feedRound + functionsLatestRound;
    }
    
    /**
     * @notice Get answer from specific round (fallback to price feed)
     * @param roundId Round ID to query
     * @return Price from the specified round
     */
    function getAnswer(uint256 roundId) external view override returns (int256) {
        return priceFeed.getAnswer(roundId);
    }
    
    /**
     * @notice Get timestamp from specific round (fallback to price feed)
     * @param roundId Round ID to query
     * @return Timestamp from the specified round
     */
    function getTimestamp(uint256 roundId) external view override returns (uint256) {
        return priceFeed.getTimestamp(roundId);
    }
    
    // *****************************//
    // *** CHAINLINK FUNCTIONS *** //
    // *************************** //
    
    /**
     * @notice Callback function for Chainlink Functions
     * @param requestId Request ID
     * @param response Encoded response from off-chain computation
     * @param err Error message if any
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (!validRequestIds[requestId]) {
            revert UnexpectedRequestID(requestId);
        }
        
        // Clear the request ID
        validRequestIds[requestId] = false;
        
        if (response.length == 0) {
            revert EmptyResponse();
        }
        
        // Decode the response (expecting price as int256)
        int256 price = abi.decode(response, (int256));
        
        // Update Functions oracle data
        functionsLatestAnswer = price;
        functionsLatestTimestamp = block.timestamp;
        functionsLatestRound++;
        
        emit FunctionsResponse(requestId, price, block.timestamp);
        emit AnswerUpdated(price, functionsLatestRound, block.timestamp);
    }
    
    // ************************//
    // *** ADMIN FUNCTIONS *** //
    // *********************** //
    
    /**
     * @notice Update Chainlink Functions configuration
     * @param _donId New DON ID
     * @param _subscriptionId New subscription ID
     * @param _gasLimit New gas limit
     */
    function updateConfiguration(
        bytes32 _donId,
        uint64 _subscriptionId,
        uint32 _gasLimit
    ) external onlyOwner {
        if (_subscriptionId == 0 || _gasLimit == 0) revert InvalidConfiguration();
        
        donId = _donId;
        subscriptionId = _subscriptionId;
        gasLimit = _gasLimit;
        
        emit ConfigurationUpdated(_donId, _subscriptionId, _gasLimit);
    }
    
    /**
     * @notice Update API source code
     * @param _newSource New JavaScript source code
     */
    function updateApiSource(string memory _newSource) external onlyOwner {
        apiSource = _newSource;
        emit ApiSourceUpdated(_newSource);
    }
    
    /**
     * @notice Toggle Chainlink Functions on/off
     * @param _enabled Enable or disable Functions
     */
    function toggleFunctions(bool _enabled) external onlyOwner {
        functionsEnabled = _enabled;
        emit FunctionsToggled(_enabled);
    }
    
    /**
     * @notice Emergency mode - falls back to price feed only
     * @param _enabled Enable or disable emergency mode
     */
    function toggleEmergencyMode(bool _enabled) external onlyOwner {
        emergencyMode = _enabled;
        emit EmergencyModeToggled(_enabled);
    }
    
    // **********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //
    
    /**
     * @notice Get both oracle prices and timestamps for comparison
     * @return functionsPrice Price from Chainlink Functions
     * @return functionsTime Timestamp from Chainlink Functions
     * @return feedPrice Price from traditional price feed
     * @return feedTime Timestamp from traditional price feed
     */
    function getOracleComparison() external view returns (
        int256 functionsPrice,
        uint256 functionsTime,
        int256 feedPrice,
        uint256 feedTime
    ) {
        functionsPrice = functionsLatestAnswer;
        functionsTime = functionsLatestTimestamp;
        
        (, feedPrice, , feedTime, ) = priceFeed.latestRoundData();
    }
    
    /**
     * @notice Check which oracle source is being used for latest answer
     * @return isUsingFunctions True if using Functions, false if using price feed
     */
    function getActiveSource() external view returns (bool isUsingFunctions) {
        if (emergencyMode || !functionsEnabled) {
            return false;
        }
        
        (, , , uint256 feedTimestamp, ) = priceFeed.latestRoundData();
        return functionsLatestTimestamp > feedTimestamp;
    }
    
    /**
     * @notice Get the traditional Chainlink price feed address
     * @return Address of the underlying price feed
     */
    function getPriceFeedAddress() external view returns (address) {
        return address(priceFeed);
    }
}