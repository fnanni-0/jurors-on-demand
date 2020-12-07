// SPDX-License-Identifier: MIT

/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/** @title Auto Appealable Arbitrator
 *  @dev This is a centralized arbitrator which either gives direct rulings or provides a time and fee for appeal.
 */
contract JurorsOnDemandArbitrator is IArbitrator {
    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 1.

    address public owner = msg.sender;
    uint256 public constant WORD_SIZE = 32;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 public constant DEFAULT_MIN_PRICE = 0;
    uint256 public constant NOT_PAYABLE_VALUE = (2**256-2)/2; // High value to be sure that the appeal is too expensive.

    enum JurorStatus { Vacant, Assigned, RuleGiven, Challenged }

    struct ExtraData {
        uint256 deadline;
        uint256 minPrice;
        uint256 rulingTimeout;
        uint256 appealTimeout;
        IArbitrator backupArbitrator;
        address[] whiteList;
        bytes backupArbitratorExtraData;
    }

    struct Dispute {
        IArbitrable arbitrated; // The contract requiring arbitration.
        address payable juror;
        JurorStatus jurorStatus;
        DisputeStatus status;   // The status of the dispute.
        IArbitrator backupArbitrator; // Arbitrator which will judge the case if the ruling is appealed
        bytes backupArbitratorExtraData;
        uint256 choices;           // The amount of possible choices, 0 excluded.
        uint256 minPrice;
        uint256 maxPrice;          // The max amount of fees collected by the arbitrator.
        uint256 deadline;
        uint256 lastInteraction;
        uint256 sumDeposit;
        uint256 rulingTimeout;     // The current ruling.
        uint256 ruling;            // The current ruling.
        uint256 appealCost;        // The cost to appeal. 0 before it is appealable.
        uint256 appealTimeout;     // Only valid fot the first appeal. Afterwards, the backup arbitrator handles the appeal periods
        uint256 appealID;          // disputeID of the dispute delegated to the backup arbitrator.
    }

    Dispute[] public disputes;
    uint256 public arbitrationCostMultiplier; // Multiplier for calculating the arbitration cost related part of the deposit translator must pay to self-assign a task.
    uint256 public assignationMultiplier; // Multiplier for calculating the task price related part of the deposit translator must pay to self-assign a task.
    uint256 public challengeMultiplier; // Multiplier for calculating the value of the deposit challenger must pay to challenge a translation.

    /** @dev To be emitted when a translator assigns a task to himself.
     *  @param _disputeID The ID of the assigned task.
     *  @param _juror The address that was assigned to the task.
     *  @param _price The task price at the moment it was assigned.
     */
    event DisputeAssigned(uint256 indexed _disputeID, address indexed _juror, uint256 _price);

    modifier onlyOwner {require(msg.sender==owner, "Can only be called by the owner."); _;}

    /** @dev Constructor. 
     */
    constructor() {

    }

    /** @dev Cost of arbitration. Accessor to arbitrationPrice.
     *  @return Minimum amount to be paid.
     */
    function arbitrationCost(bytes memory) public view override returns(uint) {
        return DEFAULT_MIN_PRICE;
    }

    /** @dev Cost of appeal. If appeal is not possible, it's a high value which can never be paid.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @return fee Amount to be paid.
     */
    function appealCost(uint _disputeID, bytes memory) public view override returns(uint fee) {
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.status == DisputeStatus.Appealable)
            return dispute.appealCost;
        else
            return NOT_PAYABLE_VALUE;
    }

    /** @dev Create a dispute. Must be called by the arbitrable contract.
     *  Must be paid at least arbitrationCost().
     *  @param _choices Amount of choices the arbitrator can make in this dispute. When ruling <= choices.
     *  @param _rawExtraData Can be used to give additional info on the dispute to be created.
     *  @return disputeID ID of the dispute created.
     */
    function createDispute(uint256 _choices, bytes calldata _rawExtraData) public payable override returns(uint256 disputeID) {
        ExtraData memory extraData = decodeExtraData(_rawExtraData);
        require(msg.value >= extraData.minPrice, "Not enough ETH.");
        require(extraData.deadline >= block.timestamp, "The deadline should be in the future.");
        require(extraData.backupArbitrator != IArbitrator(0x0), "Invalid backup arbitrator.");

        Dispute storage dispute = disputes.push(); // Create the dispute and return its number.
        dispute.arbitrated = IArbitrable(msg.sender);
        dispute.jurorStatus = JurorStatus.Vacant;
        dispute.status = DisputeStatus.Waiting;
        dispute.backupArbitrator = extraData.backupArbitrator; // Arbitrator which will judge the case if the ruling is appealed
        dispute.backupArbitratorExtraData = extraData.backupArbitratorExtraData;
        dispute.choices = _choices;
        dispute.minPrice = extraData.minPrice;
        dispute.maxPrice = msg.value;          // The max amount of fees collected by the arbitrator.
        dispute.deadline = extraData.deadline;
        dispute.lastInteraction = block.timestamp;
        dispute.rulingTimeout = extraData.rulingTimeout;
        dispute.ruling = 0;
        dispute.appealCost = 0;
        dispute.appealTimeout = extraData.appealTimeout;

        emit DisputeCreation(disputeID, IArbitrable(msg.sender));

        disputeID = disputes.length; // disputeID E [1, uint256(-1)]
    }

    /** @dev Assigns a specific task to the sender. Requires a translator's deposit.
     *  Note that the deposit should be a little higher than the required value because of the price increase during the time the transaction is mined. The surplus will be reimbursed.
     *  @param _disputeID The ID of the task.
     */
    function assignDispute(uint256 _disputeID) external payable {
        Dispute storage dispute = disputes[_disputeID];
        require(block.timestamp <= dispute.deadline, "The deadline has already passed.");
        require(dispute.jurorStatus == JurorStatus.Vacant, "Task has already been assigned or reimbursed.");

        uint256 price = dispute.minPrice +
            ((dispute.maxPrice - dispute.minPrice) * (block.timestamp - dispute.lastInteraction)) /
            (dispute.deadline - dispute.lastInteraction);
        uint256 backupArbitrationCost = dispute.backupArbitrator.arbitrationCost(dispute.backupArbitratorExtraData);
        uint256 assignationDeposit = backupArbitrationCost.mulCap(arbitrationCostMultiplier) / MULTIPLIER_DIVISOR;
        assignationDeposit = assignationDeposit.addCap(price.mulCap(assignationMultiplier) / MULTIPLIER_DIVISOR);

        require(msg.value >= assignationDeposit, "Not enough ETH provided as warranty.");
        // Reimburse juror the difference between maximum and actual price.
        uint256 remainder = msg.value - assignationDeposit;
        if (remainder > 0)
            msg.sender.send(remainder);

        dispute.juror = msg.sender;
        dispute.jurorStatus = JurorStatus.Assigned;
        dispute.minPrice = price; // for jurorStatus >= Assigned, minPrice stores the real price
        dispute.sumDeposit = assignationDeposit;
        dispute.lastInteraction = block.timestamp;

        emit DisputeAssigned(_disputeID, msg.sender, price);
    }

    /** @dev Give a ruling. UNTRUSTED.
     *  @param _disputeID ID of the dispute to rule.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 means "Not able/wanting to make a decision".
     */
    function giveRuling(uint _disputeID, uint _ruling) external {
        Dispute storage dispute = disputes[_disputeID];
        require(_ruling <= dispute.choices, "Invalid ruling.");
        require(dispute.juror <= msg.sender, "Only the assigned juror can rule.");
        require(dispute.status == DisputeStatus.Waiting, "The dispute must be waiting for arbitration.");
        require(dispute.jurorStatus == JurorStatus.Assigned, "The juror has to be assigned.");
        require(block.timestamp - dispute.lastInteraction <= dispute.rulingTimeout, "Ruling period has passed.");

        dispute.ruling = _ruling;
        dispute.jurorStatus = JurorStatus.RuleGiven;
        dispute.lastInteraction = block.timestamp; // Timestamp at which the appeal period starts
        dispute.status = DisputeStatus.Appealable;

        emit AppealPossible(_disputeID, dispute.arbitrated);
    }

    /** @dev Appeal a ruling. Note that it has to be called before the arbitrator contract calls rule.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @param _extraData Can be used to give extra info on the appeal.
     */
    function appeal(uint _disputeID, bytes memory _extraData) public payable override {
        Dispute storage dispute = disputes[_disputeID];
        // uint appealFee = appealCost(_disputeID, _extraData);
        require(dispute.status == DisputeStatus.Appealable, "The dispute must be appealable.");
        require(block.timestamp < dispute.lastInteraction + dispute.appealTimeout, "The appeal period is over.");

        if (dispute.appealID == 0) {
            // create dispute in backup arbitrator
            uint256 challengeDeposit = dispute.minPrice.mulCap(challengeMultiplier) / MULTIPLIER_DIVISOR;
            uint256 backupArbitrationCost = dispute.backupArbitrator.arbitrationCost(dispute.backupArbitratorExtraData);
            challengeDeposit = challengeDeposit.addCap(backupArbitrationCost.mulCap(arbitrationCostMultiplier) / MULTIPLIER_DIVISOR);
            require(msg.value >= challengeDeposit, "Value is less than required appeal fee");
            dispute.appealID = dispute.backupArbitrator.createDispute{value: backupArbitrationCost}(dispute.choices, dispute.backupArbitratorExtraData);
            dispute.jurorStatus = JurorStatus.Challenged;
            dispute.sumDeposit += msg.value;
        } else {
            // appeal backup arbitrator ruling
            uint256 backupAppealCost = dispute.backupArbitrator.appealCost(_disputeID, dispute.backupArbitratorExtraData);
            require(msg.value >= backupAppealCost, "Value is less than required appeal fee");
            dispute.appealID = dispute.backupArbitrator.createDispute{value: backupAppealCost}(dispute.choices, dispute.backupArbitratorExtraData);
        }
    
        dispute.status = DisputeStatus.Waiting;
        emit AppealDecision(_disputeID, IArbitrable(msg.sender));
    }

    /** @dev Execute the ruling of a dispute after the appeal period has passed. UNTRUSTED.
     *  @param _disputeID ID of the dispute to execute.
     */
    function executeRuling(uint _disputeID) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status == DisputeStatus.Appealable, "The dispute must be appealable.");
        require(block.timestamp >= dispute.appealPeriodEnd, "The dispute must be executed after its appeal period has ended.");
        require(dispute.jurorStatus == JurorStatus.Ruled, "The juror must have ruled.");

        dispute.status = DisputeStatus.Solved;
        dispute.arbitrated.rule(_disputeID, dispute.ruling);
    }

    function withdrawRemainingFees(uint256 _disputeID) external returns(uint256 remainder) {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status == DisputeStatus.Solved, "The dispute must be solved.");
        if (dispute.jurorStatus == JurorStatus.Vacant || dispute.jurorStatus == JurorStatus.Assigned) {
            remainder = dispute.maxPrice;
            dispute.arbitrated.send(remainder);
        } else if (dispute.jurorStatus == JurorStatus.Ruled) {
            remainder = dispute.maxPrice - dispute.minPrice; // At this point minPrice == real price.
            dispute.arbitrated.send(remainder);
        }
        dispute.maxPrice = 0;
        dispute.minPrice = 0;
    }

     /** @dev Gets a subcourt ID and the minimum number of jurors required from a specified extra data bytes array.
     *  @param _rawExtraData The extra data bytes array.
     *  @return extraData .
     */
    function decodeExtraData(bytes calldata _rawExtraData) internal view returns (ExtraData memory extraData) {
        // TODO: check vulnerabilities regarding calldata manipulation
        uint256 whiteListSize;
        
        // Decode fix sized data
        (
            extraData.deadline, 
            extraData.minPrice, 
            extraData.rulingTimeout, 
            extraData.appealTimeout, 
            extraData.backupArbitrator, 
            whiteListSize,
        ) = abi.decode(
            _rawExtraData[0:WORD_SIZE*6], 
            (uint256, uint256, uint256, uint256, address, uint256)
        );
        
        // Decode whitelist if any
        extraData.whiteList = new address[](whiteListSize);
        uint256 start = WORD_SIZE*6;
        for (uint256 i = 0; i < whiteListSize; i++) {
            extraData.whiteList[i] = abi.decode(
                _rawExtraData[start + i*WORD_SIZE: start + (i+1)*WORD_SIZE], 
                (address)
            );
        }

        // Decode extraData of the backup arbitrator
        start += whiteListSize*WORD_SIZE;
        uint256 remainingBytes = _rawExtraData.length - start;
        extraData.backupArbitratorExtraData = new bytes(remainingBytes);
        for (uint256 i = 0; i < remainingBytes; i++) {
            extraData.backupArbitratorExtraData[i] = _rawExtraData[start + i];
        }
    }

    /** @dev Return the status of a dispute (in the sense of ERC792, not the Dispute property).
     *  @param _disputeID ID of the dispute to rule.
     *  @return status The status of the dispute.
     */
    function disputeStatus(uint _disputeID) public view override returns(DisputeStatus status) {
        Dispute storage dispute = disputes[_disputeID];
        if (disputes[_disputeID].status==DisputeStatus.Appealable && block.timestamp>=dispute.appealPeriodEnd) // If the appeal period is over, consider it solved even if rule has not been called yet.
            return DisputeStatus.Solved;
        else
            return disputes[_disputeID].status;
    }

    /** @dev Return the ruling of a dispute.
     *  @param _disputeID ID of the dispute.
     *  @return ruling The ruling which have been given or which would be given if no appeals are raised.
     */
    function currentRuling(uint _disputeID) public view override returns(uint ruling) {
        return disputes[_disputeID].ruling;
    }

    /** @dev Compute the start and end of the dispute's current or next appeal period, if possible.
     *  @param _disputeID ID of the dispute.
     *  @return start The start of the period.
     *  @return end The End of the period.
     */
    function appealPeriod(uint _disputeID) public view override returns(uint start, uint end) {
        Dispute storage dispute = disputes[_disputeID];
        return (dispute.appealPeriodStart, dispute.appealPeriodEnd);
    }

}
