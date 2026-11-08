# PriceShare

A light Auction House price addon for WoW Forever, shared with your friends.

- **Scans for you.** Opening the Auction House starts a Full Scan, at most once every 15 minutes
  (the server's limit). The **Quick Scan** button works in between: it loads every page of an
  empty search. Scans from VendorSnipe or Auctionator count too.
- **Shares with friends.** Friends who also run PriceShare are found automatically, and the newest
  scan anyone has is passed around in the background, so not everyone has to scan.
- **Tooltip.** Shows the cheapest price per item and what everything you have of it is worth,
  e.g. `20c each`, `Your 39: 7s 80c`.

Nothing is ever shown to other players. Everything goes through hidden addon messages.

## Install

1. Click **Code > Download ZIP** on this page.
2. Open the zip and copy the folder `PriceShare-main` into
   `World of Warcraft\_forever_\Interface\AddOns`.
3. Rename it from `PriceShare-main` to **`PriceShare`**.
4. Restart WoW.

## Update

Double-click **`Update-PriceShare.bat`** inside `Interface\AddOns\PriceShare`. It downloads the
newest version over the old one. Then type `/reload` in game (it tells you if a full restart is
needed instead).

When a friend has a newer version than you, PriceShare tells you in chat.

## Linking up with friends

You need the same faction and a realm that shares your Auction House (on Forever, realms of
one cluster and type do, e.g. CAMWOW EU4 Realm 6 PvP and Realm 8 PvP), and be linked one of
these ways:

- Battle.net friends, or in the same guild: automatic.
- In-game friends: **both** of you need the other on your friends list.
- Invite each other to a group once: you stay linked after that.
- Friends of friends find each other through the friend they share.
- Otherwise: one of you types `/ps ping Name`. The other sees
  *"Name runs PriceShare and wants to share prices"* and types the `/ps add Name` it shows.
  You're linked from then on.

`/ps check` shows what PriceShare sees, and `/ps ping Name` tests one person.

## Commands (`/ps` or `/priceshare`)

| Command | What it does |
| --- | --- |
| `/ps` | status |
| `/ps scan` | Full Scan now (Auction House open, once per 15 min) |
| `/ps quick` | Quick Scan: every search page, no 15 min wait |
| `/ps auto on\|off` | Full Scan when you open the Auction House |
| `/ps friends` | who runs PriceShare, their versions |
| `/ps sync` | ask friends for newer prices now |
| `/ps add Name` / `remove` / `block` / `unblock` | manage who you share with |
| `/ps check`, `/ps ping Name` | find out why someone isn't linked |
| `/ps share on\|off`, `/ps tooltip on\|off`, `/ps chat on\|off` | settings |

## Still not linking?

PriceShare keeps a diagnostic log of the last 400 hellos, replies and game errors (no prices,
nothing is sent anywhere). `/ps log` shows the end of it. After a `/reload` it's saved in
`World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\PriceShare.lua`:
send that file to whoever is helping you.
