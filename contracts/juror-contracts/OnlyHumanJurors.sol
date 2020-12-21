// SPDX-License-Identifier: MIT

/**
 *  @authors: [@fnanni-0]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7;

import '.././JurorsOnDemand.sol'

/**
 * @title ProofOfHumanity Interface
 * @dev See https://github.com/Proof-Of-Humanity/Proof-Of-Humanity.
 */
interface IProofOfHumanity {
    enum Status {None, Vouching, PendingRegistration, PendingRemoval}

    function getSubmissionInfo(address _submissionID)
        external
        view
        returns (
            Status status,
            uint64 submissionTime,
            uint64 renewalTimestamp,
            uint64 index,
            bool registered,
            bool hasVouched,
            uint256 numberOfRequests
        );
}

contract OnlyHumanJurors {

    struct DisputeData {
        address payable juror;
        bool withdrawn;
    }

    IProofOfHumanity public immutable proofOfHumanity;
    JurorsOnDemandArbitrator public immutable jurorsOnDemand;

    mapping(uint256 => DisputeData) public disputes;

    /** @dev Constructor.
     *  @param _proofOfHumanity The Proof Of Humanity registry to reference. TRUSTED.
     *  @param _jurorsOnDemand The jurorsOnDemand arbitrator. TRUSTED.
     */
    constructor(
        IProofOfHumanity _proofOfHumanity,
        JurorsOnDemandArbitrator jurorsOnDemand
    ) {
        proofOfHumanity = _proofOfHumanity;
        jurorsOnDemand = _jurorsOnDemand;
    }

    function assignDispute(uint256 _disputeID) external payable {
        (, , , , bool registered, , ) = proofOfHumanity.getSubmissionInfo(msg.sender);
        require(registered == true, "Caller is not a registered human");

        uint256 deposit = jurorsOnDemand.getDepositValue(_disputeID, msg.sender);
        require(msg.value >= deposit, "Not enough ETH");
        msg.sender.send(msg.value - deposit);
        DisputeData storage disputeData = disputes[_disputeID];
        disputeData.juror = msg.sender;

        jurorsOnDemand.assignDispute{value: deposit}(_disputeID);
    }

    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        require(disputes[_disputeID].juror == msg.sender, "Caller is not the juror");
        jurorsOnDemand.giveRuling(_disputeID, _ruling);
    }

    function withdraw(uint256 _disputeID) external {
        DisputeData storage disputeData = disputes[_disputeID];
        require(disputeData.withdrawn == false, "Already withdrawn.");

        uint256 amount = jurorsOnDemand.amountTransferredToJuror(_disputeID);
        disputeData.withdrawn = true;
        disputeData.juror.send(amount);
    }

    receive() external payable {}
}