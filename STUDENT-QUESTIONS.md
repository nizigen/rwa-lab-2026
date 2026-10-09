# STUDENT-QUESTIONS.md — Discussion questions (goes inside your submission zip)

Answer directly under each question. 150–300 words each — **reasoning over length**.

The sections follow the four planks of the bridge. There are no standard answers; these are the
real point of the lab.

---

## A. Custody — where the asset actually is (plank a)

**A1.** In Lab 1, `totalCollateral()` read the vault's own ERC-20 balance, and the chain could
prove the invariant. Here, `MockTBillCustodian.realHoldings()` is just a number that a permissioned
address can move. Write the equivalent of `totalCollateral() == totalSupply()` for *this* system.
What does it actually assert, and what does it no longer prove?

> Your answer:

For a simple position before any redemption tickets exist, the economically intended relation is `vault.reserveBalance() + custodian.realHoldings() == vault.totalClaimValue()`. Both sides are expressed in six-decimal USDC units; comparing the raw eighteen-decimal share supply directly with holdings would be meaningless. This is a reconciliation target, not an invariant implemented or guaranteed by these contracts. Immediately after subscribing at par, the vault holds the payment even though the custodian reports zero, so ignoring the cash buffer would incorrectly describe the whole fund as unbacked.

Once redemptions exist, the reconciliation must include queue cash and settled liabilities. Unsettled shares are still in total supply, but their tickets promise the enqueue NAV. An illustrative solvency condition is `vault cash + reported holdings + queue cash >= value of non-escrowed shares + pendingAssets + totalClaimable`. This avoids counting escrowed shares twice and includes cash already reserved for claims.

Even a matching equation proves only consistency between on-chain balances and reported numbers. `recordPurchase()` can increase the custodian's integer without receiving cash or buying a security. It does not prove ownership, correct valuation, freedom from liens, or recoverability in insolvency. Those require independent custody records, reconciliations, and enforceable legal rights. Neither queue invariant supplies that missing evidence.

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> Your answer:

The legal structure determines what the token actually represents when ordinary operations stop. The contract can record balances and authorize redemption, but it cannot make Treasury securities belong to investors, exclude them from an issuer's bankruptcy estate, or order a bank to return assets. An SPV connects the software's share ledger to a defined pool of assets and a documented set of investor rights. Asset segregation, custody agreements, and the fund's governing documents therefore affect the technical assumptions about backing and settlement.

Bankruptcy remoteness reduces exposure to the issuer's creditors; it does not guarantee that every custodian failure produces an immediate, full recovery. If the custodian fails, the holder's entitlement depends on the actual legal arrangement. Properly segregated securities may be recoverable for the SPV and its investors, while an unsecured cash deposit or missing assets may lead to delays, competing claims, or losses. Owning an ERC-20 alone does not establish a direct claim against the custodian.

I would require the documents to identify the legal issuer, asset owner, holder rights, insolvency procedures, and the administrator authorized to reconcile the token ledger with beneficial ownership. In this lab, `MockTBillCustodian.realHoldings()` demonstrates the trust boundary. It creates no SPV, custody account, or enforceable entitlement. The code simulates the accounting interface; the legal agreement must supply the asset claim.

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> Your answer:

A single reporter can fail through compromise, dishonesty, error, or unavailability. A stolen signing key permits unauthorized NAV updates; independent signing hardware and a threshold of separately controlled approvers reduce that risk. A dishonest reporter can deliberately inflate redemption payouts or underprice subscriptions; independent fund administration, custody reconciliation, and liability for false statements make that harder. A decimal or valuation mistake can misprice every account at once; explicit units, independent calculations, and deviation limits with reviewed overrides mitigate mistakes. An unavailable reporter can leave an otherwise honest NAV stale; monitoring, backup reporters, and a maximum permitted age should stop pricing-sensitive operations until fresh data arrives.

There is also a concrete backdoor in this repository. `TBillVault.attest()` checks `REPORTER_ROLE`, but `MockPriceFeed.setPrice()` is public and has no access control. Anyone can bypass the vault and change its feed directly. A production feed must authenticate its writers or verify signed reports; securing only the wrapper is insufficient.

The reported NAV determines subscription shares and locked redemption amounts, but the two queue invariants verify escrow and settled cash accounting. They can both pass while the NAV is false and honest holders lose value. Consequently, multiple signatures alone are insufficient if all signers rely on the same false source. Independent evidence of custody and valuation is the necessary second check.

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> Your answer:

An honest NAV can become unfair simply by remaining unchanged after the underlying assets move. Suppose the feed still says one dollar per share, while the real fund value has increased to $1.10. An informed customer can subscribe at the old price and receive more shares than the payment should buy. Once the feed catches up, those shares claim part of the gain that economically belonged to existing investors. If the real value instead falls to $0.90 while the feed remains at one dollar, an informed existing holder can enqueue redemption at the overstated price. The queue locks that payout, so a subsequent truthful update does not correct the ticket. Remaining holders bear the resulting shortfall.

The attacker need not control the reporter or submit a false number. The advantage comes from knowing current information while the contract prices transactions using old information. T+1 settlement makes the timing particularly relevant because a locked obligation survives the reporting delay.

This mock cannot meaningfully detect staleness. `latestRoundData()` returns `block.timestamp` as `updatedAt` on every read, even if `answer` has not changed for months. Adding only a reader-side age check would therefore always treat it as fresh. A real implementation needs a stored report timestamp updated when a report is accepted, authenticated round data, and explicit behavior for stale reports, such as suspending new subscriptions and redemption pricing while allowing already funded claims.

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Your answer:

Enqueueing exchanges an exposed share position for a fixed cash promise. If a customer escrows 100 shares at a one-dollar NAV, the ticket locks 100 USDC. If NAV reaches $1.10 before settlement, the payout stays 100 USDC rather than becoming 110. The redeemer gives up the intervening upside, while the fund retains the residual economic gain for the continuing investors, assuming assets are properly valued and fund accounting allocates that residual to them. Conversely, a fall after enqueue leaves the redeemer protected by the locked promise and shifts the loss toward the remaining fund.

This allocation can be reasonable if the disclosed dealing policy establishes enqueue as the valuation cutoff. It is problematic when the enqueue NAV is stale or when customers can choose the cutoff after observing information the reporter has not published. In this mock, updating NAV does not automatically distribute residual gains or recompute a fair NAV from assets; that economic interpretation requires accounting outside the contract.

I would use a disclosed dealing window and an independently determined NAV at its cutoff, with appropriate transaction-cost allocation. Pricing at settlement is another possible design, but the ticket must then explicitly promise variable proceeds rather than a fixed amount.

`vault.reserveBalance() >= queue.pendingAssets()` is not a valid general invariant. Cash may already be invested in T-Bills, and increased value can remain at the custodian until sale and payment. Economic backing and immediately available settlement cash are different quantities.

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Your answer:

The Reserve Primary Fund reported a $0.97 NAV in September 2008 and delayed redemption proceeds. The SEC subsequently permitted suspension of redemptions and payments while liquidation could not proceed without impairing NAV. This combined asset losses with a liquidity crisis. [SEC staff FAQ](https://www.sec.gov/divisions/investment/guidance/reservefundmmffaq.htm)

USDC's March 2023 disruption involved access to $3.3 billion deposited at Silicon Valley Bank and interrupted banking operations. Circle maintained its one-dollar redemption commitment and announced access to the deposits following government action. It later reported substantially clearing its minting and redemption backlog by March 15. That was a restoration of dollar settlement, rather than a fund paying a reduced floating NAV. [Circle reserve update](https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes), [Circle operations update](https://www.circle.com/blog/march-15-update-on-usdc-operations)

For a T-Bill fund, closing the redemption channel should mean a clearly announced restriction on new requests or settlement, with existing tickets, ordering, and funded entitlements preserved. Any haircut or alternative allocation needs an explicit legal process, not silent deletion or repricing of the queue.

The lab's `pause()` disables token balance changes. It blocks transfers, subscriptions that mint, enqueue transfers, and settlement burns, so it cannot selectively manage a cash shortage. Importantly, the implemented queue's `claim()` transfers USDC without changing tBILL balances, so already settled claims remain payable. I would prefer separate controls for subscriptions, new redemption requests, and unfunded settlement, while preserving funded withdrawals. Published triggers, independent authorization, review deadlines, and clear resumption criteria would limit discretionary suspension.

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> Your answer:

A regulated fund should admit holders according to its disclosed investor eligibility, identity checks, and applicable restrictions. Payment alone should not override admission. Equally, a customer waiting for an ordinary KYC review should not be treated as if misconduct has been established. The line should be clear before subscription: what evidence is required, who reviews it, when approval expires, and how errors can be challenged. Sensitive identity documents should remain off-chain; the registry should expose only the authorization needed to enforce token ownership.

This lab puts the guard in `TBillToken._update()`, which checks both nonzero endpoints. A whitelisted sender cannot transfer to an unapproved receiver. Minting checks the recipient, and burning checks the holder whose balance decreases. Therefore, removing a holder affects their existing position, not merely future purchases. Queue escrow also requires the queue to be whitelisted. These consequences should be part of the policy rather than surprises discovered during redemption.

I would place routine registry decisions with a dedicated compliance function under documented procedures, with independent approval for exceptional freezes. Administrators able to grant `COMPLIANCE_ROLE` also influence the boundary, so their keys need separate control and an audit trail. There should be clear explanations and an appeal route for administrative mistakes, while legally restricted cases follow the appropriate confidential process. Investor admission rules should not be casually changed by the trading desk or NAV reporter.

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> Your answer:

Issuer powers have a practical case: a regulated fund may need to restrict prohibited holders, comply with a valid court order, or restore ownership after a documented operational error. Without intervention, a token ledger could become inconsistent with the fund's legally recognized ownership. However, those same powers let a compromised or abusive issuer freeze legitimate investors, destroy their positions, or favor selected customers. A technically valid transaction is not evidence that its legal justification is valid. Concentrating compliance, minting, pausing, and administration in one key makes the consequences worse.

Ex4.3 exposes an implementation conflict. Removing Alice from the whitelist prevents her transfers, but `burn(alice, amount)` also calls `_update()` and fails on the same sender check. `MINTER_ROLE` authorizes the entry point; it does not bypass the whitelist or global pause. Temporarily whitelisting a frozen holder to seize assets is an awkward workaround that also restores ordinary transfer permission.

For a production design, I would specify a separate, narrowly scoped seizure or forced-transfer procedure with its own legal authorization, custody destination, reason record, and independent approvals. It should preserve economic ownership evidence instead of silently erasing it. Routine minting should belong to the subscription mechanism, compliance decisions to compliance officers, extraordinary seizure to a separate threshold committee, and role administration to independently governed multisignature control. Emergency freezes can be immediate, but should expire or receive timely review. Investors need disclosed powers, notices where permitted, audit records, and a process for correcting mistakes.

---

## E. Tests (Tier 1 required — this is Ex2, Ex3 and Ex4)

Turn the red tests green in `test/exercises/01_BridgeTasks.t.sol` to cover the scenarios below, and
write your test function names here:

| Plank | Scenario | Your test function name |
|---|---|---|
| a | Shares exist while the custodian holds nothing | `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` |
| a | `realHoldings()` moves with no cash moving | `test_Ex2_RealHoldingsIsJustANumber` |
| b | The claim value floats while the share count stays | `test_Ex3_TheClaimFloats_TheShareCountDoesNot` |
| b | One `attest` re-prices every holder at once | `test_Ex3_OneCallMovesTheWholeBook` |
| d | A non-whitelisted address cannot receive shares, even by paying | `test_Ex4_NoKyc_NoShares_EvenIfYouPay` |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | `test_Ex4_TransferChecksBothEndpoints` |
| d | Removing an address freezes that holder — and blocks a burn | `test_Ex4_FreezeBeatsConfiscation` |

Then write one more scenario you consider **most likely to be exploited** on a tokenized fund, and
say which plank it breaks:

> Your answer:

The most likely exploit in this exact deployment is direct manipulation of the publicly writable mock feed, breaking plank (b), attestation. A KYC-approved attacker can subscribe while NAV is one dollar, call `feed.setPrice(2e8)` without `REPORTER_ROLE`, and enqueue their shares at the doubled price. Resetting NAV afterward does not reduce `assetsLocked`. If an authorized settler processes the ticket and sufficient vault cash exists, the attacker claims the inflated payout. Settlement is still role-gated, so writing a false NAV alone does not grant immediate withdrawal authority; the loss materializes when the false ticket is funded.

In a production fund with authenticated oracle writes, I would prioritize the related stale-NAV scenario: an informed customer exits at an old high price or subscribes at an old low price before a truthful update. Neither case necessarily breaks escrow conservation or settlement solvency. Shares can be correctly escrowed and cash correctly funded while the fund transfers value to the attacker.

The mock should remain explicitly a teaching component. A real feed needs restricted writers or verified reports, a stored reporting timestamp, independent valuation reconciliation, and pricing cutoffs. Monitoring should compare NAV changes and ticket liabilities with verified assets, rather than assuming green accounting invariants establish fair prices.
