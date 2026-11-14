# PriceShare

A light Auction House price addon for WoW Forever, shared with your friends.

- **Scans for you.** Opening the Auction House starts a Full Scan, at most once every 15 minutes
  (the server's limit). The **Quick Scan** button works in between: it loads every page of an
  empty search. Scans from VendorSnipe or Auctionator count too.
- **Shares with friends.** Friends who also run PriceShare are found automatically, and the newest
  scan anyone has is passed around in the background, so not everyone has to scan.
- **Tooltip.** Shows the cheapest price per item and what everything you have of it is worth,
  e.g. `20c each`, `Your 39: 7s 80c`.
- **Price lookup.** Look up any item's price anywhere, even items you don't have, in a window laid
  out like the Auction House's Buy tab. Open it with the minimap button, the **Price Lookup**
  button above the Auction House, a key (Key Bindings > AddOns > PriceShare) or `/ps find`.

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

When a friend has a newer version than you, PriceShare reminds you in chat every 5 minutes (not
during combat), with a sound, until you update. The sound is a Warcraft III Peon's "Work work."
by default; pick another (or none) on the minimap button's right-click menu, or with `/ps sound`.

## Price lookup

- **Search** by name (any part of it, any order of words), paste or Shift-click an item into the
  search box, or pick a category on the left.
- **Columns:** how many are listed, the cheapest price, what it realistically sells for (where the
  cheapest 10% of listed units end), and when its price last changed. Click a header to sort.
- **Hover** a row for the item's tooltip, **Shift-click** to link it in chat, **Ctrl-click** to try
  it on. Click it for details, including what yours are worth.
- **Auction House** button: your faction's prices or the goblin one's (Booty Bay, Gadgetzan,
  Everlook). **Filter**: only some rarities.
- Items that sold out show as "none listed" when you search for them.

The prices come from the newest scan anyone in your PriceShare group has. Scans carry item numbers
only, so the first time you open the window it learns item names from the game in the background
(the bottom line shows how far along it is). It keeps them, so after that searches are instant.

## Linking up with friends

Prices are shared between friends of the same faction on the same Auction House. On WoW Forever
all CAMWOW EU PvP realms share one (EU4 and EU5 checked in game); PvE realms are kept apart.

- **Battle.net friends:** automatic, on any realm. New or newly online friends are greeted right away.
- **Same guild, or in a group together once:** automatic, and you stay linked after that.
- **In-game friends:** automatic when **both** of you have the other on your friends list.
- **Friends of friends** find each other through the friend they share.
- Otherwise: one of you types `/ps ping Name`. The other sees
  *"Name runs PriceShare and wants to share prices"* and types the `/ps add Name` it shows.

Friends on another Auction House still show in `/ps friends`, marked "other Auction House";
their prices are never mixed into yours.

`/ps check` shows what PriceShare sees, and `/ps ping Name` tests one person.

## Commands (`/ps` or `/priceshare`)

| Command | What it does |
| --- | --- |
| `/ps` | status |
| `/ps find [name]` | price lookup window (also the minimap button) |
| `/ps minimap` | show or hide the minimap button |
| `/ps sound [number]` | the update reminder's sound |
| `/ps remind` | show the update reminder now |
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
