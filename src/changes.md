- **The denominator is now derived, not stored.** Every deposit takes a snapshot and computes `totalSupplyAt(snap) − Σ balanceOfAt(excluded, snap)` on the spot. Numerator and denominator now come from the same source of truth, so claims always sum to ≤ the deposit by construction. `yieldBearingSupply`, `admitTreasury`, and the 270M constant are gone entirely — that whole insolvency/stranding class disappears, and "admitting" treasury tokens is now just a normal transfer out of the (excluded) treasury, picked up automatically at the next snapshot.

- **One deposit function.** `depositFirstYield`/`depositRegularYield` collapsed into `depositYield`. The Sablier special-casing was only needed because the denominator was hand-maintained; now the escrow is just an excluded address, so locked tokens are subtracted automatically and withdrawn tokens start earning the moment they land in an investor's wallet. No separate path, no "first" flag to guard.

- **Exclusion is frozen per epoch.** Closes the toggle hole: at deposit, each excluded address is recorded in `epochExcluded[epochId]`. So an address excluded when an epoch opened can never later be un-excluded to claim that past epoch (its balance was already subtracted from that denominator), and an address that was legitimately included keeps its claim even if it's excluded later. Exclusion changes only ever affect future epochs.

- **The emergency drain is neutered.** `emergencyWithdrawRewards` (drain everything) is replaced by `sweepExcess`, which can only remove `balance − outstanding` — i.e. rounding dust and any USDT sent in directly. It can never reduce the balance below what holders are owed, so it's no longer a rug vector. A separate `rescueToken` handles foreign tokens but is explicitly blocked from touching the yield asset. Lifetime `totalDeposited`/`totalClaimed` track the liability.

- **Interfaces updated:** IGobiToken now exposes `totalSupplyAt` (it was missing — the derivation needs it; token already implements it), and `IAdapter` matches the new surface.

Two deployment notes to wire up, since they're external to the contract:

- **Grant the distributor `SNAPSHOT_ROLE` on the token** post-deploy, or every `depositYield` reverts at the `snapshot()` call.
- **Exclude the treasury before the first deposit.** The constructor only seeds the Sablier escrow; call `addExclusion(treasury)` (and any other non-yield-bearing operational wallets) before depositing, or their balances will wrongly count as yield-bearing.