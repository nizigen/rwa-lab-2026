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

Before anyone requests redemption, I would compare `vault.reserveBalance() + custodian.realHoldings()` with `vault.totalClaimValue()`. All three values use six-decimal USDC units. The raw share supply has eighteen decimals, so it cannot be compared directly with a USDC amount. After a subscription, the payment is still in the vault even if the custodian reports no T-Bills. That cash belongs in the comparison.

The queue makes the calculation harder. Escrowed shares are still in total supply, but their tickets already have a fixed payout. A fuller check would compare vault cash, reported holdings, and queue cash against the value of shares outside escrow, `pendingAssets`, and `totalClaimable`. This avoids counting the same redemption twice. It is a proposed accounting check, not a rule that these contracts enforce.

Even if the numbers match, I would only conclude that the records agree. `recordPurchase()` changes a number without transferring cash or buying a T-Bill. The equation cannot prove that securities exist, belong to the fund, or can be recovered. Those questions need custody statements and legal documents. The queue tests only check share and cash accounting.

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> Your answer:

The token needs a legal structure because the contract cannot control a bank account or a Treasury security. It can record who holds shares and who has requested payment. An SPV and its agreements explain which assets those shares represent and who owns them. Without that link, a correct token balance could still leave its holder with no clear claim to the assets.

Keeping assets separate from the issuer can reduce the risk that the issuer's creditors take them. It does not mean every custodian failure ends with a full refund. If securities are properly segregated, the SPV may be able to recover them. Cash deposits, missing assets, or a dispute over ownership may cause losses or a long delay. The token holder's rights depend on the fund and custody documents; holding an ERC-20 does not automatically give a direct claim against the custodian.

I would check who the issuer and asset owner are, what rights investors have, and what happens in bankruptcy. The lab only models the reporting interface. `realHoldings()` does not create an SPV, a custody account, or a legal right to Treasury securities.

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> Your answer:

A reporter's key can be stolen. Separate signing devices and approval from more than one independent signer would make a single stolen key less useful. A reporter can also lie about NAV. Comparing reports with independent custody records and a fund administrator's valuation would help detect that. Mistakes are another risk: a wrong decimal scale can change every holder's claim at once. Unit checks and limits on unusual price changes could catch some errors before they reach the feed.

If the reporter stops working, the old price remains. A backup reporter and an age limit would help, with new pricing stopped until a fresh report is available. Multiple signers still need separate sources; agreeing on the same bad input does not make it correct.

There is a more basic issue in this lab. `attest()` requires `REPORTER_ROLE`, but anyone can call `MockPriceFeed.setPrice()` directly. A real feed would need restricted writers or checked signatures too. The two queue invariants do not validate NAV. They check that pending shares stay in escrow and settled claims have enough cash. Both can pass while a false price harms other holders.

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> Your answer:

Suppose the feed still shows one dollar per share, but the fund is now worth $1.10 per share. Someone who knows the new value can subscribe at the old price and receive too many shares. When NAV is updated, the new shares get part of the gain that belonged to earlier holders. The reporter does not need to lie for this to happen.

The reverse works for redemption. If the true value falls to $0.90 but the feed still says one dollar, a holder can enqueue at the old price. The ticket locks its payout when it is created. Updating NAV later does not reduce that payout, so the remaining fund bears the extra cost. A settlement delay gives the stale price more time to be used.

This mock has a misleading timestamp. `latestRoundData()` returns the current `block.timestamp` every time it is read, even when the price has not changed. An age check on that value would always pass. A real feed needs to store when the report was accepted. I would stop new subscriptions and redemption pricing when that report is stale, while allowing claims that already have cash set aside.

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Your answer:

A redemption ticket fixes the amount at enqueue time. If I enqueue 100 shares when NAV is one dollar, the ticket promises 100 USDC. A rise to $1.10 before settlement does not turn that into 110 USDC. The redeemer gives up the gain during the wait. Continuing holders can benefit from it if the fund's accounting correctly assigns the remaining value to them. If NAV falls instead, the fixed payout protects the redeemer and leaves more of the loss with those who stay.

I think this can be fair when the valuation cutoff is clear before investors trade. It is less fair if the price is stale and someone can choose to exit after learning about a fall. The lab does not calculate NAV from real assets or automatically assign these gains. That part depends on the fund's accounting.

I would use a stated dealing window and an independent valuation at its cutoff. Pricing at settlement is possible too, but then the promised payout must be variable. I would not require vault cash to cover every pending request at all times: some backing may still be in T-Bills that need to be sold.

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Your answer:

The Reserve Primary Fund reported a $0.97 NAV in September 2008 and delayed redemption payments. The SEC later allowed it to suspend redemptions and payments during liquidation. Asset losses and a shortage of cash both mattered. [SEC staff FAQ](https://www.sec.gov/divisions/investment/guidance/reservefundmmffaq.htm)

USDC's March 2023 depeg involved $3.3 billion at Silicon Valley Bank and disrupted banking access. Circle kept its one-dollar redemption commitment. After government action restored access to the deposits, it reported clearing most of its minting and redemption backlog by March 15. [Circle reserve update](https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes), [Circle operations update](https://www.circle.com/blog/march-15-update-on-usdc-operations)

For a T-Bill fund, closing redemption should mean a stated limit on new requests or settlement. Existing tickets and their order should remain recorded. A haircut needs a disclosed legal process, rather than deleting requests or changing payouts without notice.

The lab's pause blocks token transfers, minting, enqueue transfers, and settlement burns together. That is too broad for a cash shortage. Already settled `claim()` calls still work because they transfer USDC without changing tBILL balances. I would use separate controls for subscriptions, new requests, and settlement. Cash already reserved for claims should remain withdrawable, with clear conditions for reopening the other operations.

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> Your answer:

A regulated fund should say who can hold its shares before taking a subscription. Paying USDC should not bypass those rules. A customer waiting for KYC approval also needs a clear explanation of the delay and a way to correct mistakes. Identity documents should stay off-chain. The contract only needs the approval status required to control share ownership.

In this lab, `_update()` checks both nonzero endpoints. An approved sender cannot send shares to an unapproved receiver. Minting checks the new holder, and burning checks the holder whose balance is reduced. Removing someone from the list therefore affects shares they already own, including their ability to redeem. The queue must also be whitelisted so it can receive escrowed shares.

I would give routine decisions to a compliance team using written rules. Exceptional freezes should need an independent review. The administrator who can grant `COMPLIANCE_ROLE` also has control over admission, so that key should have separate protection and an audit trail. Customers need an appeal route for ordinary errors. Any change to eligibility should follow the fund's stated policy, rather than a decision by the trading desk or the NAV reporter.

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> Your answer:

There are reasons to let an issuer intervene. A fund may need to follow a court order, restrict a prohibited holder, or correct a proven ownership error. Those powers can keep the token record consistent with the fund's legal records. They can also be abused. A stolen key or a dishonest issuer could freeze a legitimate investor or destroy their shares. A successful transaction alone does not prove that the action was justified.

Ex4.3 shows a conflict between freezing and burning. Once Alice is removed from the whitelist, `_update()` rejects both her transfers and a burn of her balance. `MINTER_ROLE` allows the burn function to be called, but does not bypass the whitelist or pause. Temporarily approving Alice again would also restore her normal transfer permission.

I would give seizure a separate, limited procedure with a recorded reason, a defined destination, and independent approval. Compliance officers should handle admission, the subscription mechanism should mint, and a separate committee should approve exceptional seizures. Role changes should use a multisignature account. Emergency freezes need timely review. Investors should know these powers before joining and have a process for correcting mistakes.

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

An approved attacker could subscribe at NAV one dollar, then call the public `feed.setPrice(2e8)` and enqueue at twice that price. This breaks plank (b), attestation. The attacker does not need `REPORTER_ROLE` to write to this mock feed. Changing NAV back does not change the ticket's `assetsLocked`.

The attacker still needs an authorized settler to process the ticket and enough vault cash to fund it. If that happens, the inflated payout takes value from the other holders. The queue can keep correct escrow and cash balances throughout. I would test direct feed writes and check the resulting payout, rather than treating passing queue invariants as proof that NAV is fair.
