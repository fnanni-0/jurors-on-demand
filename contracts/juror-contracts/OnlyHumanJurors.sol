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

    IProofOfHumanity public immutable proofOfHumanity;
    JurorsOnDemandArbitrator public immutable jurorsOnDemand;

    mapping(uint256 => address) public disputeIDtoJuror;

    /** @dev Constructor.
     *  @param _proofOfHumanity The Proof Of Humanity registry to reference.
     *  @param _jurorsOnDemand The jurorsOnDemand arbitrator.
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
        disputeIDtoJuror[_disputeID] = msg.sender;

        jurorsOnDemand.assignDispute{value: deposit}(_disputeID);
    }

    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        require(disputeIDtoJuror[_disputeID] == msg.sender, "Caller is not the juror");
        jurorsOnDemand.giveRuling(_disputeID, _ruling);
    }

    function withdraw(uint256 _disputeID) external {
        require(disputeIDtoJuror[_disputeID] == msg.sender, "Caller is not the juror");

        DisputeStatus status = jurorsOnDemand.disputeStatus(_disputeID);
        uint256 ruling = jurorsOnDemand.currentRuling(_disputeID);
    }

    receive() external payable {}
}