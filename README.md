# Yield Sweeper — Reactive Omni Buildathon

**Track:** Set It and Forget It
**Left:** `yield-sweeper`
**Chain:** Reactive Lasna (testnet) → Base Sepolia (origin/destination)

> A personal vault that **sweeps** your farming/yield rewards to a cold wallet
> automatically — no bot, no keeper, no server, no cron job. Powered by the
> Reactive Network.

---

## The problem this solves

Farming and DeFi rewards pile up in hot wallets across many pools and chains.
Claiming them is tedious, and leaving them in a hot wallet (the one you paste
into mint tools, marketplaces, and farming dapps) is the riskiest place to keep
them.

The usual fix — a bot on a VPS that polls balances and signs transfers — means
another hot key, another server, another thing that dies at 3am and gets drained.

**Yield Sweeper removes the bot.**

- A **vault** contract on the *origin* chain receives your rewards
  (it is the `payee`/recipient for your farming positions).
- A **reactive contract** on Lasna watches the vault for `Deposited` events.
- When accumulated deposits for a whitelisted token cross your threshold, the
  Reactive Network itself delivers a **callback** to the vault, which forwards
  the funds to your cold wallet under rules you set (token whitelist, minimums).
- Nothing off-chain has to stay online. No key that can move funds ever leaves
  your cold wallet's control.

## Architecture

```
  Origin chain (Base Sepolia 84532)
  ┌───────────────────────────────────────────┐
  │  YieldSweeperVault (0x…)                  │
  │  ┌─────────────────────────────────────┐  │
  │  │ coldWallet (immutable)              │  │
  │  │ callbackSender (mutable, set post)  │  │
  │  │ minSweepByToken[token] → threshold  │  │
  │  └─────────────────────────────────────┘  │
  │  events: Deposited(token, depositor, amt) │
  │  receive: sweep(address,address,uint256)  │
  └───────────────────────────────────────────┘
        │
        │  event log (Deposited)
        ▼
  Reactive Network (Lasna 5318007)
  ┌───────────────────────────────────────────┐
  │  YieldSweeperReactive (0x…)              │
  │  ├─ subscribes to Deposited on vault     │
  │  ├─ accumulated[token] += amount         │
  │  └─ if accumulated ≥ threshold:          │
  │        requestCallbackV_1_0(             │
  │          chainId=84532,                  │
  │          recipient=vault,                │
  │          payload=sweep(address(0),token,0)│
  │        )                                 │
  └───────────────────────────────────────────┘
        │  authenticated callback (via proxy)
        ▼
  Vault.sweep(...) → forwards funds to coldWallet
```

## Why this fits "Set It and Forget It"

- **Personal purpose:** if you farm, you *have* this problem. The tool you'd
  actually keep running.
- **Event-driven logic:** not a cron — it reacts to real deposits.
- **Usefulness:** moves yield out of harm's way automatically.
- **Craft:** clean inheritance (`AbstractReactive`/`AbstractCallback`),
  documented, fully tested.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/Vault.sol` — `YieldSweeperVault` | Origin (Base Sepolia) | Holds reward & receives authenticated callback |
| `src/YieldSweeperReactive.sol` — `YieldSweeperReactive` | Reactive Lasna | Subscribes to deposits, fires sweep callback |

## Deployment

Prereqs: Foundry, a private key, Sepolia ETH (for gas + faucet), and testnet
REACT.

### Deployed live (2026-11-24)

| Contract | Chain | Address |
|---|---|---|
| `YieldSweeperVault` | Base Sepolia (84532) | `0x679790Ab23c02Ce73e2D2FaC001c7db3FBDaf31E` |
| `YieldSweeperReactive` | Lasna (5318007) | `0x679790Ab23c02Ce73e2D2FaC001c7db3FBDaf31E` |

Cold wallet (owner): `0x7824b8F71bCBc0E15810EefA48D5f45decEF84D5` (hackathon test
wallet; the same EOA deploys both contracts, so both inherit the same CREATE
address across chains).

**Verified end-to-end sweep (live on Base Sepolia):**

1. Deposit `0.002 ETH` → Vault: tx `0xe0915ce48ce760a8cb6e6b0db07cbb7d8307fa3a63b8b9093ffe604c17fd04bc` (block 62950476), emitted `Deposited(address(0), …)`.
2. Reactive Network relayed the event and delivered the authenticated callback.
3. Vault swept `0.002 ETH` to cold wallet: `Swept` log at block 62950483 in tx `0xfef0d545e9ab5b0b3fa9a29516a1bee6c54c79004bd312e605d19920473d5a96` (7 blocks after deposit).
4. Post-sweep vault ETH balance = `0`; cold wallet received the funds.

`Reactscan` shows `SUBSCRIPTIONS: 1` for the reactive contract, `ADDRESS TYPE: REACTIVE CONTRACT`.

### Deploy from scratch

### 1. Deploy the vault (origin chain)

```bash
export BASE_SEPOLIA_RPC=https://sepolia.base.org
export PRIVATE_KEY=0x...
export COLD_WALLET=0xYourColdWallet

forge script script/Deploy.s.sol:DeployVault \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

Note the vault address → `VAULT`.

### 2. Deploy the reactive contract (Lasna)

```bash
export LASNA_RPC=https://lasna-rpc.rnk.dev
export VAULT=0x<vault from step 1>

forge script script/Deploy.s.sol:DeployReactive \
  --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast
```

Note the reactive address → `REACTIVE`.

### 3. Bind the callback sender (origin chain)

```bash
cast send $VAULT "setCallbackSender(address)" $REACTIVE \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

### 4. Configure thresholds

```bash
# whitelist USDC and require 50 USDC before sweeping
cast send $VAULT "setMinSweep(address,uint256)" $USDC 50000000 \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

### 5. Get testnet REACT (for reactive gas)

Send ≥1 Sepolia ETH to the Reactive faucet on **Base Sepolia**
`0x2afaFD298b23b62760711756088F75B7409f5967` (or Ethereum Sepolia
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`) → receive 100 lREACT on Lasna
per 1 ETH. Max 5 ETH per tx (500 lREACT). Gas for the reactive deploy on Lasna
is ~0.27 lREACT, so 0.5–1 lREACT is plenty.

## Testing

```bash
forge test -vv
```

16 tests cover: deposits (ERC20 + native), authenticated sweep through the
proxy, partial sweep, unauthorized-sender revert, manual owner-only sweep, and
the reactive contract's accumulation/threshold/callback logic.

## Requirements this satisfies

- ✅ Public, open-source repository
- ✅ Deployed contract addresses (see deployment logs)
- ✅ Transaction hashes showing origin event → callback → sweep (in loop runs)
- ✅ Demo video (<3 min)
- ✅ Built entirely during the event (Nov 5 – Dec 5)
