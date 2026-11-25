# Yield Sweeper — Submission Kit (Reactive Omni Buildathon)

Semua materi submit sudah siap. Salin-tempel ke form DoraHacks setelah login.

## Project name
**Yield Sweeper** — autonomous reward sweeper on Reactive Network

## One-liner / tagline
A reactive Vault that watches deposit events cross-chain and automatically sweeps
yield rewards to a cold wallet once they cross a threshold — no manual claims.

## Category / Track
"Set It and Forget It" — personal automations anyone can build, no contract
experience needed (Reactive Omni Buildathon).

## Description (paste into form)
Yield rewards routinely pile up in protocol Vaults and sit there until someone
manually sweeps them — a slow, forgettable, error-prone chore. **Yield Sweeper**
removes the human from the loop with Reactive Network.

* A **Vault** contract on Base Sepolia holds the deposited funds. Any deposit
  emits a `Deposited` event.
* A **Reactive contract** on Lasna subscribes to that event. When cumulative
  deposits pass a configurable threshold, it fires an authenticated callback
  straight back into the Vault.
* The Vault authenticates the sender (`onlyCallbackSender`) and sweeps the funds
  to a cold wallet — automatically, around 1s blocks, with instant finality.

No keeper bots, no off-chain relayer, no manual claim button. Set the threshold
once and forget it.

## Deployed addresses
| Contract | Chain | Address |
|---|---|---|
| YieldSweeperVault | Base Sepolia (84532) | `0x679790Ab23c02Ce73e2D2FaC001c7db3FBDaf31E` |
| YieldSweeperReactive | Lasna (5318007) | `0x679790Ab23c02Ce73e2D2FaC001c7db3FBDaf31E` |
| Cold wallet | — | `0x7824b8F71bCBc0E15810EefA48D5f45decEF84D5` |

Note: both contracts deploy from the same EOA, so they share a CREATE address.

## GitHub repo
https://github.com/muladiputra-dev/yield-sweeper (public, `main`, 16 tests pass)

## Demo video
`https://github.com/muladiputra-dev/yield-sweeper/raw/main/assets/yield_sweeper_demo.mp4`
(1:28, shows live on-chain transaction screenshots)

## Live evidence (transaction hashes)
* Deposit 0.002 ETH → Vault: `0xe0915ce48ce760a8cb6e6b0db07cbb7d8307fa3a63b8b9093ffe604c17fd04bc` (block 62950476, `Deposited`)
* Finish callback (Vault): `0xfef0d545e9ab5b0b3fa9a29516a1bee6c54c79004bd312e605d19920473d5a96` (block 62950483, `Swept` 0.002 ETH, 7 blocks after deposit)
* Vault ETH balance after sweep: 0 (funds moved to cold wallet)
* Reactscan: `SUBSCRIPTIONS: 1`, `ADDRESS TYPE: REACTIVE CONTRACT`
