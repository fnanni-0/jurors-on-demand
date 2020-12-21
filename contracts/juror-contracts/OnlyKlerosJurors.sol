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
 * @title KlerosLiquid Interface
 * @dev See https://github.com/kleros/kleros/blob/master/contracts/kleros/KlerosLiquid.sol.
 */
interface IKlerosLiquid {
    struct Juror {
        uint96[] subcourtIDs;
        uint256 stakedTokens; // The juror's total amount of tokens staked in subcourts.
        uint256 lockedTokens; // The juror's total amount of tokens locked in disputes.
    }

    function jurors(address _account) external view returns (Juror);
}

contract OnlyKlerosJurors {

    struct DisputeData {
        address payable juror;
        bool withdrawn;
    }

    IKlerosLiquid public immutable klerosLiquid;
    JurorsOnDemandArbitrator public immutable jurorsOnDemand;

    mapping(uint256 => DisputeData) public disputes;
    uint256 public minStake;

    /** @dev Constructor.
     *  @param _klerosLiquid The Proof Of Humanity registry to reference. TRUSTED.
     *  @param _jurorsOnDemand The jurorsOnDemand arbitrator. TRUSTED.
     *  @param _minStake Minimum stake a juror should have in order to assign themself a dispute.
     */
    constructor(
        IKlerosLiquid _klerosLiquid,
        JurorsOnDemandArbitrator jurorsOnDemand,
        uint256 _minStake;
    ) {
        klerosLiquid = _klerosLiquid;
        jurorsOnDemand = _jurorsOnDemand;
        minStake = _minStake;
    }

    function assignDispute(uint256 _disputeID) external payable {
        IKlerosLiquid.Juror juror = klerosLiquid.jurors(msg.sender);
        require(juror.stakedTokens >= _minStake, "Caller has not staked enough in Kleros courts.");

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