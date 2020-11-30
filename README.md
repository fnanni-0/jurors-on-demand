# Jurors on demand

This is an arbitrator smart contract that connects parties in dispute with jurors. Some of its logic was inspired by [Linguo](https://linguo.kleros.io/home).

# Features

## Price
The arbitration cost is set by the arbitrable contract instead of by the arbitrator. Once the dispute is created, the price of arbitration will increase linearly from `minPrice` to `maxPrice` as the `deadline` approaches. At anytime, a juror can assign the dispute to themself at the current price. 

Some of the benefits of this price strategy:
- The price of arbitration is defined for each dispute. As disputes vary greatly in risk and complexity, it makes sense that different disputes are more expensive to resolve than others.
- Jurors and arbitrators, for whatever reason, could be interested in solving disputes pro bono.
- For some disputes, it seems like a waste of time and resources to ask N jurors in a complex court system to give a ruling. Some disputes might be easily solvable by single willing, compentent juror.

## Jurors
The bid for jurors can be open to anyone or restricted to a whitelist of addresses provided by the arbitrable.

Why whitelist jurors? Parties could be interested in hiring a specific juror, due to competence, reputation or whatever reason. Even though the system provides a safety net against bad jurors, this safety net (the backup arbitrator) is expensive and time-consuming.

I believe this has the potential to create a virtous circle, in which jurors actively seek to increase their efficiency/efficacy and reputation so that parties consider adding them in the whitelist.

Also notice that the juror could be another smart contract.

## Appeals
In order to make this arbitrator robust against malicious, negligent or controversial jurors, appeals are delegated to a backup arbitrator specified by the arbitrable contract which created the dispute. 

Notice that this does not make JurorsOnDemand an arbitrable contract, although the backup arbitrator will think of it that way. JurorsOnDemand is still an arbitrator contract.

# Future work

- Implement hash-not-store pattern to save gas.
- Implement a tokenize version of the contract, in order to allow payments in any ERC20 token.

