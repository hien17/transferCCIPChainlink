// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DataConsumerV3 {
    AggregatorV3Interface internal dataFeed;

     /**
     * Network: Avalanche Testnet (Fuji)
     * Aggregator: LINK/USD
     * Address: 0x34C4c526902d88a3Aa98DB8a9b802603EB1E3470
     */
    constructor() {
        dataFeed = AggregatorV3Interface(
            0x34C4c526902d88a3Aa98DB8a9b802603EB1E3470
        );
    }

    /**
     * Returns the latest answer.
     */

    function getChainlinkDataFeedLastestAnswer() public view returns (int) {
       (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
       ) = dataFeed.latestRoundData();
       return answer;
    }

}

contract TokenTransferor is OwnerIsCreator {
    using SafeERC20 for IERC20;
    DataConsumerV3 _dataConsumerV3;
    //Custom errors to provide more descriptive revert messages
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); //used to make sure contract has enough balance to cover the fees
    error NothingToWithdraw();  // used when tryin to withdraw ether but there's nothing to withdraw
    error FailedToWithdrawEth(address owner, address target, uint256 value); //used when the withdrawal of Ether fails
    error DestinationChainNotAllowListed(uint64 destinationChainSelector); //used when the destination has not been allowlisted by the contract owner
    error InvalidReceiverAddress(); //used when the receiver address is 0
    
    //event emitted when the tokens are transferred to an account on another chain
    event TokensTransferred(
        bytes32 indexed messageId, //the unique id of the message
        uint64 indexed destinationChainSelector, // the chain selector of the destination chain
        address receiver, //the address of the receiver on the destination chain
        address token, //the token address that was transferred
        uint256 amount, //the amount of tokens transferred
        address feeToken, // the token address used to pay CCIP fees
        uint256 fees // the fee paid for sending the message through CCIP
    );

    // Mappings to keep track of the balances of Ether and ERC20 tokens balance of the user has deposited in the contract
    mapping(address => uint256) public etherBalance;
    mapping(address => mapping(address => uint256)) public tokenBalance;

    //mapping to keep track of allowlisted destination chains
    mapping(uint64 => bool) public allowListedChains;

    IRouterClient private s_router;
    IERC20 private s_linkToken;
    IERC20 private s_ccipBnMToken;

    /// @notice Constructor initializes the contract with the router address
    /// @param _router The address of the router contract
    /// @param _link The address of the link contract
    /// @param _dataConsumerV3Address The address of data consumer contract
    constructor(address _router, address _link, address _ccipBnM, address _dataConsumerV3Address) {
        s_router = IRouterClient(_router);
        s_linkToken = IERC20(_link);
        s_ccipBnMToken = IERC20(_ccipBnM);
        _dataConsumerV3 = DataConsumerV3(_dataConsumerV3Address);
    }

    /// @dev Modifier that checks if the chain with the given destinationChainSelector is allowed
    /// @param _destinationChainSelector The selector of the destination chain
    modifier onlyAllowlistedChain(uint64 _destinationChainSelector) {
        if (!allowListedChains[_destinationChainSelector]) 
            revert DestinationChainNotAllowListed(_destinationChainSelector);
        _;
    }

    /// @dev Modifier that checks the receiver address is not 0
    /// @param _receiver The receiver address
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    function getLINKUSDPrice() public view returns (uint256) {
        return uint256(_dataConsumerV3.getChainlinkDataFeedLastestAnswer());
    }
    
    /// @notice This function convert amount of USD to respective amount of LINK
    /// @param amountUSD The amount of USD to convert to LINK
    /// @return amountLINK The respective amount of LINK
    function USDToLINK(uint256 amountUSD) public view returns(uint256 amountLINK) {
        uint256 LINKPrice = getLINKUSDPrice();
        amountLINK = amountUSD * (1 ether) / LINKPrice * 10**8 * (1 wei);
    }

    /// @notice This function convert amount of LINK to respective amount of USD
    /// @param amountLINK The amount of LINK to convert to USD
    /// @return amountUSD The respective amount of USD
    function LINKToUSD(uint256 amountLINK) public view returns(uint256 amountUSD) {
        uint256 LINKPrice = getLINKUSDPrice();
        amountUSD = amountLINK * LINKPrice / (1 ether * 10**8) + 1;
    }

    // @dev Updates the allowlist status of a destination chain for transactions
    /// @notice This function can only be called by the owner
    /// @param _destinationChainSelector The selector of the destination chain to be updated
    /// @param allowed The allowlist status to be set for the destination chain 
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external {
        allowListedChains[_destinationChainSelector] = allowed;
    }

    function getFees(
        uint64 _destinationChainSelector,
        address _receiver,
        // address _token, // in this case we use ccipBnM token to transfer so we don't need token address
        uint256 _amount
    )
        public
        view
        onlyAllowlistedChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (uint256)
    {
        // create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken means fees are paid in LINK)
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            address(s_ccipBnMToken),
            _amount,
            address(s_linkToken)
        );

        // get the fee required to send the message
        uint256 fees = s_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );
        return fees;
    }

    /// @notice Transfer ccipBnM token to receiver on the destination chain
    /// @notice Pay in LINK
    /// @dev Assumes your contract has sufficient LINK tokens to pay for the fees
    /// @param _destinationChainSelector The identifier for the destination blockchain
    /// @param _receiver The address of the receiver on the destination blockchain
    // / @param _token The address of the token to be transferred
    /// @param _amount The amount of tokens to be transferred
    /// @return messageId The ID of the message that was sent
    function transferTokensPayLINKDirect(
        uint64 _destinationChainSelector,
        address _receiver,
        // address _token, // in this case we use ccipBnM token to transfer so we don't need token address
        uint256 _amount
    )
        external
        onlyAllowlistedChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        // create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken means fees are paid in LINK)
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            address(s_ccipBnMToken),
            _amount,
            address(s_linkToken)
        );

        // get the fee required to send the message
        uint256 fees = s_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > s_linkToken.balanceOf(msg.sender))
            revert NotEnoughBalance(s_linkToken.balanceOf(msg.sender),fees);

        // transfer LINK token from msg.sender to contract with condition that msg.sender has approved contract for transferring enough LINK
        s_linkToken.safeTransferFrom(msg.sender, address(this), fees);
        // approve the router to transfer LINK tokens on contract's behalf. It wil spend the fees in LINK
        s_linkToken.approve(address(s_router), fees);

        // transfer ccipBnM token from msg.sender to contract with condition that msg.sender has approved contract for transferring enough ccipBnM
        s_ccipBnMToken.safeTransferFrom(msg.sender, address(this), _amount);
        // approve the router to spend token on contract's behalf. It will spend the amount of the given token
        s_ccipBnMToken.approve(address(s_router), _amount);

        // send the message through the router and store the returned message ID
        messageId = s_router.ccipSend(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // emit an event with message details
        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            address(s_ccipBnMToken),
            _amount,
            address(s_linkToken),
            fees
        );

        // return the message ID
        return messageId;
    }

    /// @notice Transfer tokens to receiver on the destination chain
    /// @notice Pay in LINK
    /// @notice The token must be in the list of the supported tokens
    /// @notice This function can only be called by the owner
    /// @dev Assumes your contract has sufficient LINK tokens to pay for the fees
    /// @param _destinationChainSelector The identifier for the destination blockchain
    /// @param _receiver The address of the receiver on the destination blockchain
    /// @param _token The address of the token to be transferred
    /// @param _amount The amount of tokens to be transferred
    /// @return messageId The ID of the message that was sent
    function transferTokensPayLINK(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    )
        external
        onlyAllowlistedChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        // create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken means fees are paid in LINK)
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _token,
            _amount,
            address(s_linkToken)
        );

        // get the fee required to send the message
        uint256 fees = s_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > s_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(s_linkToken.balanceOf(address(this)),fees);

        // approve the router to transfer LINK tokens on contract's behalf. It wil spend the fees in LINK
        s_linkToken.approve(address(s_router), fees);

        // approve the router to spend token on contract's behalf. It will spend the amount of the given token
        IERC20(_token).approve(address(s_router), _amount);

        // send the message through the router and store the returned message ID
        messageId = s_router.ccipSend(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // emit an event with message details
        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            _token,
            _amount,
            address(s_linkToken),
            fees
        );

        // return the message ID
        return messageId;
    }
    
    /// @notice Transfer tokens to receiver on the destination chain.
    /// @notice Pay in native gas such as ETH on Ethereum or MATIC on Polgon.
    /// @notice the token must be in the list of supported tokens.
    /// @notice This function can only be called by the owner.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _token token address.
    /// @param _amount token amount.
    /// @return messageId The ID of the message that was sent.
    function transferTokensPayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    )
        external
        onlyAllowlistedChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _token,
            _amount,
            address(0)
        );

        // Get the fee required to send the message
        uint256 fees = s_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(_token).approve(address(s_router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = s_router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            _token,
            _amount,
            address(0),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Construct a CCIP messgae
    /// @dev This function will create an EVM2AnyMessage struct will all the necessary information for a tokens transfer through CCIP
    /// @param _receiver The address of the receiver 
    /// @param _token The address of the token to be transferred
    /// @param _amount The amount of tokens to be transferred
    /// @param _feeTokenAddress The address of the token to be used to pay the fees. Set address(0) for native gas
    /// @return Client.EVM2AnyMessage anEVM2AnyMessage struct which contains information for sending a CCIP message
    function _buildCCIPMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        //set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });

        // create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return 
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver), //ABI-encoded receiver address
                data: "", // no data
                tokenAmounts: tokenAmounts, // the amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    //additional arguments, setting gas limit to 0 as we are not sending any data
                    Client.EVMExtraArgsV1({gasLimit: 0})
                ),
                feeToken: _feeTokenAddress
            });
    }

    /// @notice Fallback function to allow the contract to receive Ether
    /// @dev This function has no function body, making it a default function for receiving Ether
    /// It is automatically called when Ether is transferred to the contract without any data
    receive() external payable {
        etherBalance[msg.sender] += msg.value;
    }

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails
    /// It should be called by the owner of the contract
    /// @param _beneficiary The address to which the Ether should be transferred
    function withdraw(address _beneficiary) public {
        // retrieve the balance of this contract
        uint256 amount = etherBalance[msg.sender];

        // revert if there is nothing to withdraw
        if (amount== 0) revert NothingToWithdraw();

        etherBalance[msg.sender] = 0;

        // attempt to send the funds, capturing the success status and discarding any return data
        (bool sent,) = _beneficiary.call{value: amount}("");

        // revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    /// @param _token The contract address of the ERC20 token to be withdrawn.
    function withdrawToken(
        address _beneficiary,
        address _token
    ) public {
        // Retrieve the balance of this contract
        uint256 amount = tokenBalance[msg.sender][_token];

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        tokenBalance[msg.sender][_token] = 0;

        IERC20(_token).safeTransfer(_beneficiary, amount);
    }

    /// @notice Deposit ERC20 tokens into the contract
    /// @param _token The address of the ERC20 token to be deposited
    /// @param _amount The amount of tokens to be deposited
    function depositToken(address _token, uint256 _amount) external {
        // Transfer the tokens from the sender to the contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Record the token balance
        tokenBalance[msg.sender][_token] += _amount;
    }
}