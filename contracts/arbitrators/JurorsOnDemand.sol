// SPDX-License-Identifier: MIT

/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/** @title Auto Appealable Arbitrator
 *  @dev This is a centralized arbitrator which either gives direct rulings or provides a time and fee for appeal.
 */
contract JurorsOnDemandArbitrator is IArbitrator, IArbitrable, IEvidence {
    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 1.

    address public owner = msg.sender;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 public constant DEFAULT_MIN_PRICE = 0;
    uint256 public constant NOT_PAYABLE_VALUE = (2**256-2)/2; // High value to be sure that the appeal is too expensive.
    uint256 public constant META_EVIDENCE_ID = 0;
    uint256 private constant WORD_SIZE = 32; // Used in decoding extraData

    enum JurorStatus { Vacant, Assigned, RulingGiven, Challenged, Resolved }

    struct ExtraData {
        uint64 deadline;
        uint256 minPrice;
        uint64 rulingTimeout;
        uint64 appealTimeout;
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
        uint64 deadline;
        uint64 lastInteraction;
        uint64 rulingTimeout;     // The current ruling.
        uint64 appealTimeout;     // Only valid fot the first appeal. Afterwards, the backup arbitrator handles the appeal periods
        uint256 sumDeposit;
        uint256 ruling;            // The current ruling.
        uint256 appealID;          // disputeID of the dispute delegated to the backup arbitrator.
        address[] whiteList;
        uint256 amountTransferredToJuror;
    }

    uint256 public arbitrationCostMultiplier; // Multiplier for calculating the arbitration cost related part of the deposit translator must pay to self-assign a task.
    uint256 public assignationMultiplier; // Multiplier for calculating the task price related part of the deposit translator must pay to self-assign a task.
    uint256 public challengeMultiplier; // Multiplier for calculating the value of the deposit challenger must pay to challenge a translation.

    Dispute[] public disputes;
    mapping(address => mapping(uint256 => uint256)) appealToDisputeID; // appealToDisputeID[backupArbitrator][dispute.appealID]

    /** @dev To be emitted when a translator assigns a task to himself.
     *  @param _disputeID The ID of the assigned task.
     *  @param _juror The address that was assigned to the task.
     *  @param _price The task price at the moment it was assigned.
     */
    event DisputeAssigned(uint256 indexed _disputeID, address indexed _juror, uint256 _price);

    modifier onlyOwner {require(msg.sender==owner, "Can only be called by the owner."); _;}

    /** @dev Constructor. 
     *  @param _metaEvidence A URI of a meta-evidence object for disputes, meant for backup arbitrators.
     */
    constructor(string memory _metaEvidence) {
        emit MetaEvidence(META_EVIDENCE_ID, _metaEvidence);
    }

    /** @dev Changes the multiplier for the arbitration/appeal cost part of the juror/challenger deposit.
     *  @param _arbitrationCostMultiplier A new value of the multiplier for calculating juror/challenger's deposit. In basis points.
     */
    function changeArbitrationCostMultiplier(uint256 _arbitrationCostMultiplier) public onlyOwner {
        arbitrationCostMultiplier = _arbitrationCostMultiplier;
    }

    /** @dev Changes the multiplier for the arbitration price part of juror's deposit.
     *  @param _assignationMultiplier A new value of the multiplier for calculating juror's deposit. In basis points.
     */
    function changeAssignationMultiplier(uint256 _assignationMultiplier) public onlyOwner {
        assignationMultiplier = _assignationMultiplier;
    }

    /** @dev Changes the multiplier for challengers' deposit.
     *  @param _challengeMultiplier A new value of the multiplier for calculating challenger's deposit. In basis points.
     */
    function changeChallengeMultiplier(uint256 _challengeMultiplier) public onlyOwner {
        challengeMultiplier = _challengeMultiplier;
    }

    /** @dev Cost of arbitration. Accessor to arbitrationPrice.
     *  @return Minimum amount to be paid.
     */
    function arbitrationCost(bytes calldata) external view override returns(uint256) {
        return DEFAULT_MIN_PRICE;
    }

    /** @dev Cost of appeal. If appeal is not possible, it's a high value which can never be paid.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @return fee Amount to be paid.
     */
    function appealCost(uint256 _disputeID, bytes calldata) external view override returns(uint256 fee) {
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.status != DisputeStatus.Appealable)
            fee = NOT_PAYABLE_VALUE;
            
        if (dispute.jurorStatus == JurorStatus.RulingGiven)
            fee = dispute.backupArbitrator.arbitrationCost(dispute.backupArbitratorExtraData);
        else if (dispute.jurorStatus == JurorStatus.Challenged)
            fee = dispute.backupArbitrator.appealCost(dispute.appealID, dispute.backupArbitratorExtraData);
        else
            fee = NOT_PAYABLE_VALUE;
    }

    /** @dev Create a dispute. Must be called by the arbitrable contract.
     *  Must be paid at least the minimum arbitration price specified.
     *  @param _choices Amount of choices the arbitrator can make in this dispute. ruling <= choices.
     *  @param _rawExtraData Additional information about the auction to be launched to look for jurors as well as appeal rules.
     *  @return disputeID ID of the dispute created.
     */
    function createDispute(uint256 _choices, bytes calldata _rawExtraData) external payable override returns(uint256 disputeID) {
        ExtraData memory extraData = decodeExtraData(_rawExtraData);
        require(msg.value >= extraData.minPrice, "Not enough ETH.");
        require(extraData.deadline > block.timestamp, "The deadline must be in the future.");
        require(extraData.backupArbitrator != IArbitrator(0x0), "Invalid backup arbitrator.");

        Dispute storage dispute = disputes.push(); // Create the dispute and return its number.
        dispute.arbitrated = IArbitrable(msg.sender);
        dispute.jurorStatus = JurorStatus.Vacant;
        dispute.status = DisputeStatus.Waiting;
        dispute.backupArbitrator = extraData.backupArbitrator; // Arbitrator which will judge the case if the ruling is appealed
        dispute.backupArbitratorExtraData = extraData.backupArbitratorExtraData;
        dispute.choices = _choices;
        dispute.minPrice = extraData.minPrice;
        dispute.maxPrice = msg.value; // The max amount of fees collected by the arbitrator.
        dispute.deadline = extraData.deadline;
        dispute.lastInteraction = uint64(block.timestamp);
        dispute.rulingTimeout = extraData.rulingTimeout;
        dispute.appealTimeout = extraData.appealTimeout;
        dispute.whiteList = extraData.whiteList;

        disputeID = disputes.length; // disputeID E [1, uint256(-1)]
        emit DisputeCreation(disputeID, IArbitrable(msg.sender));
    }

    /** @dev Assigns a specific task to the sender. Requires a translator's deposit.
     *  Note that the deposit should be a little higher than the required value because of the price increase during the time the transaction is mined. The surplus will be reimbursed.
     *  @param _disputeID The ID of the task.
     */
    function assignDispute(uint256 _disputeID) external payable {
        Dispute storage dispute = disputes[_disputeID];
        require(block.timestamp <= dispute.deadline, "The deadline has already passed.");
        require(dispute.jurorStatus == JurorStatus.Vacant, "Task has already been assigned or reimbursed.");

        require(isInWhiteList(_disputeID, msg.sender), "Not authorized.");

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
        dispute.lastInteraction = uint64(block.timestamp);

        emit DisputeAssigned(_disputeID, msg.sender, price);
    }

    /** @dev Give a ruling. UNTRUSTED.
     *  @param _disputeID ID of the dispute to rule.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 means "Not able/wanting to make a decision".
     */
    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        Dispute storage dispute = disputes[_disputeID];
        require(_ruling <= dispute.choices, "Invalid ruling.");
        require(dispute.juror == msg.sender, "Only the assigned juror can rule.");
        require(dispute.status == DisputeStatus.Waiting, "The dispute must be waiting for arbitration.");
        require(dispute.jurorStatus == JurorStatus.Assigned, "The juror has to be assigned.");
        require(block.timestamp - dispute.lastInteraction <= dispute.rulingTimeout, "Ruling period has passed.");

        dispute.ruling = _ruling;
        dispute.jurorStatus = JurorStatus.RulingGiven;
        dispute.lastInteraction = uint64(block.timestamp); // Timestamp at which the appeal period starts
        dispute.status = DisputeStatus.Appealable;

        emit AppealPossible(_disputeID, dispute.arbitrated);
    }

    /** @dev Appeal a ruling. Note that it has to be called before the arbitrator contract calls rule.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @param _extraData Can be used to give extra info on the appeal.
     */
    function appeal(uint256 _disputeID, bytes calldata _extraData) external payable override {
        Dispute storage dispute = disputes[_disputeID];
        require(msg.sender == address(dispute.arbitrated), "Can only be called by the arbitrable contract.");
        require(dispute.status == DisputeStatus.Appealable, "The dispute must be appealable.");

        if (dispute.jurorStatus == JurorStatus.RulingGiven) {
            require(block.timestamp < dispute.lastInteraction + dispute.appealTimeout, "The challenge period is over.");
            // create dispute in backup arbitrator
            uint256 challengeDeposit = dispute.minPrice.mulCap(challengeMultiplier) / MULTIPLIER_DIVISOR;
            uint256 backupArbitrationCost = dispute.backupArbitrator.arbitrationCost(dispute.backupArbitratorExtraData);
            require(msg.value >= challengeDeposit.addCap(backupArbitrationCost), "Value is less than required appeal fee");
            
            dispute.jurorStatus = JurorStatus.Challenged;
            dispute.appealID = dispute.backupArbitrator.createDispute{value: backupArbitrationCost}(dispute.choices, dispute.backupArbitratorExtraData);
            dispute.sumDeposit += challengeDeposit;
        } else {
            // appeal backup arbitrator ruling
            uint256 backupAppealCost = dispute.backupArbitrator.appealCost(dispute.appealID, dispute.backupArbitratorExtraData);
            require(msg.value >= backupAppealCost, "Value is less than required appeal fee");
            dispute.backupArbitrator.appeal{value: backupAppealCost}(dispute.choices, dispute.backupArbitratorExtraData);
        }
    
        emit AppealDecision(_disputeID, IArbitrable(msg.sender));
    }

    /** @dev Execute the ruling of a dispute after the appeal period has passed. UNTRUSTED.
     *  Can only be called once per dispute if the conditions are met.
     *  @param _disputeID ID of the dispute to execute.
     */
    function executeRuling(uint256 _disputeID) external {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status < DisputeStatus.Solved, "Dispute is already solved.");

        if (dispute.status == DisputeStatus.Appealable) {
            require(dispute.jurorStatus == JurorStatus.RulingGiven, "The juror's ruling must not have been challenged.");
            require(block.timestamp > dispute.lastInteraction + dispute.appealTimeout, "Cannot execute before the appeal period has ended.");

            dispute.jurorStatus = JurorStatus.Resolved;
            dispute.juror.send(dispute.sumDeposit + dispute.minPrice); // minPrice = price
            dispute.amountTransferredToJuror = dispute.sumDeposit + dispute.minPrice;
            dispute.sumDeposit = 0; // clear storage
        } else if (dispute.status == DisputeStatus.Waiting) {
            if (dispute.jurorStatus == JurorStatus.Vacant)
                require(block.timestamp > dispute.deadline, "Deadline has not passed.");
            else if ( dispute.jurorStatus == JurorStatus.Assigned)
                require(block.timestamp > dispute.lastInteraction + dispute.rulingTimeout + dispute.appealTimeout, "Ruling period has not passed.");
            else
                revert("Invalid status.");
        }

        dispute.status = DisputeStatus.Solved;
        dispute.arbitrated.rule(_disputeID, dispute.ruling);
    }

    /** @dev Gives the ruling for a dispute. Can only be called by the backup arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract and to invert the ruling in the case a party loses from lack of appeal fees funding.
     *  @param _appealID ID of the dispute in the backup arbitrator contract (NOT this contract).
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint256 _appealID, uint256 _ruling) external override {
        uint256 disputeID = appealToDisputeID[msg.sender][_appealID];
        Dispute storage dispute = disputes[disputeID];
        
        require(msg.sender == address(dispute.backupArbitrator), "Must be called by the backup arbitrator.");
        require(dispute.jurorStatus == JurorStatus.Challenged, "The dispute has already been resolved.");
        require(dispute.status == DisputeStatus.Appealable, "The dispute has already been resolved.");
        require(_ruling <= dispute.choices, "Invalid ruling.");

        // Distribute/register rewards and penalties
        if (_ruling == dispute.ruling) {
            dispute.juror.send(dispute.sumDeposit + dispute.minPrice);
            dispute.amountTransferredToJuror = dispute.sumDeposit + dispute.minPrice;
            dispute.sumDeposit = 0; // clear storage
        }

        dispute.status = DisputeStatus.Solved;
        dispute.jurorStatus = JurorStatus.Resolved;
        dispute.ruling = _ruling;
        dispute.arbitrated.rule(disputeID, _ruling);

        emit Ruling(IArbitrator(msg.sender), _appealID, _ruling);
    }

    function withdrawRemainingFees(uint256 _disputeID) external returns(uint256 remainder) {
        Dispute storage dispute = disputes[_disputeID];
        require(msg.sender == address(dispute.arbitrated), "Can only be called by the arbitrable contract.");
        require(dispute.status == DisputeStatus.Solved, "The dispute must be solved.");

        if (dispute.jurorStatus == JurorStatus.Vacant || dispute.jurorStatus == JurorStatus.Assigned) {
            remainder = dispute.maxPrice + dispute.sumDeposit;
            dispute.maxPrice = 0;
            dispute.sumDeposit = 0;
            dispute.arbitrated.send(remainder);
        } else if (dispute.jurorStatus == JurorStatus.Resolved) {
            // At this point minPrice == real price.
            // If ruling was appealed and won, get sumDeposit.
            remainder = dispute.maxPrice == 0 ? 0 : dispute.maxPrice - dispute.minPrice;
            dispute.maxPrice = 0;
            dispute.arbitrated.send(remainder);
        }
    }

    function amountTransferredToJuror(uint256 _disputeID) external view returns(uint256) {
        return disputes[_disputeID].amountTransferredToJuror;
    }

    /** @dev Extracts data from the extraData provided on the creation of a dispute.
     *  @param _rawExtraData The extra data bytes array.
     *  @return extraData decoded into ExtraData struct.
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
            (uint64, uint256, uint64, uint64, address, uint256)
        );
        
        // Decode whitelist if any
        extraData.whiteList = new address[](whiteListSize);
        uint256 start = WORD_SIZE * 6;
        for (uint256 i = 0; i < whiteListSize; i++) {
            extraData.whiteList[i] = abi.decode(
                _rawExtraData[start + i*WORD_SIZE: start + (i+1)*WORD_SIZE], 
                (address)
            );
        }

        // Decode extraData of the backup arbitrator
        start += whiteListSize * WORD_SIZE;
        uint256 remainingBytes = _rawExtraData.length - start;
        extraData.backupArbitratorExtraData = new bytes(remainingBytes);
        for (uint256 i = 0; i < remainingBytes; i++) {
            extraData.backupArbitratorExtraData[i] = _rawExtraData[start + i];
        }
    }

    /** @dev Checks if an address is allowed to rule on a given dispute.
     *  @param _disputeID ID of the dispute.
     *  @param _requester Address of the juror.
     *  @return validRequester true if the address is allowed to rule.
     */
    function isInWhiteList(uint256 _disputeID, address _requester) public view returns (bool validRequester) {
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.whiteList.length == 0)
            return true;
            
        for (uint256 i = 0; i < dispute.whiteList.length; i++)
            if (dispute.whiteList[i] == _requester)
                return true;
    }

    /** @dev Gets the deposit required for self-assigning the task.
     *  @param _disputeID The extra data bytes array.
     *  @param _juror The extra data bytes array.
     *  @return deposit The translator's deposit.
     */
    function getDepositValue(uint256 _disputeID, address _juror) external view returns (uint256 deposit) {
        Dispute storage dispute = disputes[_disputeID];
        if (block.timestamp <= dispute.deadline && dispute.jurorStatus == JurorStatus.Vacant && isInWhiteList(_disputeID, _juror)) {
            uint256 price = dispute.minPrice +
                ((dispute.maxPrice - dispute.minPrice) * (block.timestamp - dispute.lastInteraction)) /
                (dispute.deadline - dispute.lastInteraction);
            uint256 backupArbitrationCost = dispute.backupArbitrator.arbitrationCost(dispute.backupArbitratorExtraData);
            deposit = backupArbitrationCost.mulCap(arbitrationCostMultiplier) / MULTIPLIER_DIVISOR;
            deposit = deposit.addCap(price.mulCap(assignationMultiplier) / MULTIPLIER_DIVISOR);
        } else {
            deposit = NOT_PAYABLE_VALUE;
        }
    }

    /** @dev Gets the current price of a specified dispute.
     *  @param _disputeID The ID of the dispute.
     *  @return price The price of the dispute.
     */
    function getDisputePrice(uint256 _disputeID) external view returns (uint256 price) {
        Dispute storage dispute = disputes[_disputeID];
        if (block.timestamp <= dispute.deadline && dispute.jurorStatus == JurorStatus.Vacant && isInWhiteList(_disputeID, _juror)) {
            price = dispute.minPrice +
                ((dispute.maxPrice - dispute.minPrice) * (block.timestamp - dispute.lastInteraction)) /
                (dispute.deadline - dispute.lastInteraction);
        }
    }

    /** @dev Return the status of a dispute (in the sense of ERC792, not the Dispute property).
     *  @param _disputeID ID of the dispute to rule.
     *  @return status The status of the dispute.
     */
    function disputeStatus(uint256 _disputeID) external view override returns(DisputeStatus status) {
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.jurorStatus == JurorStatus.Challenged) {
            return dispute.backupArbitrator.disputeStatus(dispute.appealID);
        } else if (dispute.status == DisputeStatus.Appealable && block.timestamp > dispute.lastInteraction + dispute.appealTimeout) {
            // If the appeal period is over, consider it solved even if rule has not been called yet.
            return DisputeStatus.Solved;
        } else {
            return dispute.status;
        }
    }

    /** @dev Return the ruling of a dispute.
     *  @param _disputeID ID of the dispute.
     *  @return ruling The ruling which have been given or which would be given if no appeals are raised.
     */
    function currentRuling(uint256 _disputeID) external view override returns(uint256 ruling) {
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.jurorStatus == JurorStatus.Challenged)
            ruling = dispute.backupArbitrator.currentRuling();
        else
            ruling = dispute.ruling;
    }

    /** @dev Compute the start and end of the dispute's current or next appeal period, if possible.
     *  @param _disputeID ID of the dispute.
     *  @return start The start of the period.
     *  @return end The end of the period.
     */
    function appealPeriod(uint256 _disputeID) external view override returns(uint256 start, uint256 end) {
        if (dispute.jurorStatus == JurorStatus.Challenged) {
            (start, end) = dispute.backupArbitrator.appealPeriod(dispute.appealID);
        } else if (
            dispute.status == DisputeStatus.Appealable && 
            block.timestamp <= dispute.lastInteraction + dispute.appealTimeout
        ) {
            start = dispute.lastInteraction;
            end = start + dispute.appealTimeout;
        } else if (
            dispute.status == DisputeStatus.Waiting && 
            block.timestamp > dispute.lastInteraction + dispute.rulingTimeout && 
            block.timestamp <= dispute.lastInteraction + dispute.rulingTimeout + dispute.appealTimeout
        ) {
            start = dispute.lastInteraction + dispute.rulingTimeout;
            end = start + dispute.appealTimeout;
        } else {
            start = 0;
            end = 0;
        }
    }

}