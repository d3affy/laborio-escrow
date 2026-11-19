# Laborio Escrow

[![Contract tests](https://github.com/d3affy/laborio-escrow/actions/workflows/checks.yml/badge.svg)](https://github.com/d3affy/laborio-escrow/actions/workflows/checks.yml)

Solidity contracts for paying a freelancer in ERC-20 tokens as work is accepted. A client and freelancer can use one payment or divide a job into up to 32 milestones. Each agreement has its own contract address, token balance and settlement history. This is the contract component of [Lancerium](https://youtu.be/8izlhSf17vg).

## Run a deal locally

Install [Foundry](https://getfoundry.sh/introduction/installation/). CI uses Foundry **v1.4.4** and Solidity **0.8.30**. Git fetches the exact OpenZeppelin and Forge Standard Library revisions recorded in this repository.

```sh
git clone https://github.com/d3affy/laborio-escrow.git
cd laborio-escrow
git submodule update --init --depth 1
forge build
forge test --match-test test_milestone_fullFlow -vvvv
```

The example runs in Foundry's local EVM with a six-decimal test token. It creates a two-milestone agreement for 1,000 and 500 tokens. The client approves the escrow and deposits 1,500. The freelancer submits the first deliverable. On acceptance, the first 1,000 splits into 990 for the freelancer and 10 for the fee collector. Settling the second milestone closes the agreement. The trace shows each transfer and event.

## How settlement works

| Step | Who acts | Contract call |
| --- | --- | --- |
| Open | Anyone can create an agreement for named parties using an allowlisted token | `factory.createWithMilestones(...)` |
| Fund | The client approves the clone address as ERC-20 spender | `fundMilestones(value)` for the overall budget or `fundMilestone(id, value)` for an individual milestone |
| Deliver | The freelancer submits a hash that identifies the work | `submitWork(id, evidenceHash)` |
| Settle | The client releases the remainder, makes a partial payment or refunds the remaining budget to the client | `releaseMilestone`, `releasePartial`, `refundMilestone` |
| Dispute | Either party opens a dispute on work in review. The factory's arbitrator decides the payout and the client receives the remainder | `disputeMilestone`, `resolveMilestone` |

In upfront mode the escrow must hold the entire budget before work can enter review. Deposits can arrive in instalments. In per-milestone mode each deposit belongs to its specified milestone. A client can withdraw an incomplete deposit with `withdrawIncompleteFunding`; index zero selects the shared pool in upfront mode. A fully funded planned milestone can be refunded before submission.

Amounts use the token's smallest unit. A 1% fee is 100 basis points. The contracts round each payout fee down and charge it on the gross amount released. Deadlines are advisory. The review window controls when work can be resubmitted. Settlement requires an explicit transaction.

## Contract map

- [EscrowFactory.sol](src/EscrowFactory.sol) creates EIP-1167 clones, assigns agreement IDs and manages the allowed tokens, fee settings, funding pause and arbitrator.
- [Escrow.sol](src/Escrow.sol) holds deposits, tracks milestone balances, and settles payouts and refunds. For a single-payment agreement, use `factory.create` followed by `fund` and `release` or `refund`.
- [Escrow.t.sol](test/Escrow.t.sol) exercises single payments, milestones, partial releases and arbitration. [MilestoneFunding.t.sol](test/MilestoneFunding.t.sol) covers isolated budgets, incomplete deposits and funding controls.

## Verification and trust model

```sh
forge fmt --check
forge test -vv
```

The client controls ordinary payouts and refunds. Either party can move a submitted milestone into arbitration before settlement. The factory owner can change the arbitrator for existing agreements. Fee settings are copied into each clone at creation. The accounting assumes a conventional ERC-20 with stable balances and exact transfers. This reference implementation has no independent audit. All examples use local test funds.

[MIT license](LICENSE)
