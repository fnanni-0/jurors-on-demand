# Jurors on demand

This is an arbitrator smart contract that connects parties in dispute with jurors. Some of its logic was inspired by [Linguo](https://linguo.kleros.io/home).

# Features

## Price

The arbitration cost is set by the arbitrable contract instead of by the arbitrator. Once the dispute is created, the price of arbitration will increase linearly from `minPrice` to `maxPrice` as the `deadline` approaches. At anytime, a juror can assign the dispute to themself at the current price. 

Some of the benefits of this price strategy:
- The price of arbitration is defined per dispute. As disputes vary greatly in risk and complexity, it makes sense that different disputes are more expensive to resolve than others.
- Jurors and arbitrators, for whatever reason, could be interested in solving disputes pro bono.
- For some disputes, asking N jurors in a complex court system to give a ruling might be an overkill (expensive and time-consuming). A single willing, competent juror might be enough.

## Jurors

The bid for jurors can be open to anyone or restricted to a whitelist of addresses provided by the arbitrated contract.

Why whitelist jurors? Parties could be interested in hiring a specific juror, due to competence, reputation or whatever reason. I believe this has the potential to create a virtous circle, in which jurors actively seek to increase their efficiency/efficacy and reputation so that parties consider adding them in the whitelist.

I also think this system could reduce the need to create new Kleros subcourts for every new use case.

Also notice that the juror could be another smart contract.

## Appeals

In order to make this arbitrator robust against malicious, negligent or controversial jurors, appeals are delegated to a backup arbitrator specified by the arbitrable contract which created the dispute. 

JurorsOnDemand is still an arbitrator contract, although the backup arbitrator will think of it as an arbitrable contract. In KlerosLiquid there are court jumps, here we have arbitrator jumps.

The backup arbitrator could be, for example, a private arbitrator contract, this contract with another configuration or a Kleros court.


# Future work

- Restrict backup arbitrators to a whitelist maintained by the contract owner/governor.
- Using the same appeal-delegation concept, implement this same contract or another arbitrator with cross-chain logic. For example, let first round of arbitration happen on xDai chain and delegate appeals to mainnet.
- Optimize gas.
- Implement a tokenize version of the contract, in order to allow payments in any ERC20 token.
- Consider to have an individual meta-evidence for each dispute.
- Appeal extra-data is ignored?
- Explore ways to decouple arbitrator's and backup arbitrator's rulings. Not necesarily should they rule over the same thing.

