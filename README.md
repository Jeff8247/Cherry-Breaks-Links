# Cherry Breaks Links

PowerShell script for checking Cherry Collectables group breaks and printing
clean, ready-to-share break lines.

## What It Does

- Checks Cherry Collectables group breaks for a selected weekday.
- Uses Sydney time when deciding today's date.
- Prints each break with description, sport emoji, spots left, break number,
  allocation suffix where useful, and product URL.
- Groups recognised recurring breaks into `Dailies`, `Weeklies`, and
  `Other Breaks`.
- Can filter to daily and/or weekly breaks with spots left and send one Twitch
  chat message per matching break.
- Recognises weekly breaks named like `Machos`, `Spenda`, `Punterz`,
  `Sluggerz`, and `Amigos`, including loose singular/plural variants (while
  `Lil Punterz` stays in `Dailies`).
- When `-Weeklies` is used, weekly breaks are searched from the broader
  group-break listings instead of only the selected weekday.
- Can produce YouTube-friendly break lines capped at 200 characters while
  keeping spots, break number, allocation suffix, and product URL intact.
- Prints a selected day's live openings collection link when `-Day` is used.
- Sorts results from least spots left to most spots left.
- Cleans noisy title metadata such as dates, `Team Based`, `Random Type`,
  `Random Character`, duplicated separators, and Cherry's `・` separator.

Example output:

```text
Pokemon Pitch Black (7 spots) #32915 -> https://www.cherrycollectables.com.au/products/...
Topps Chrome Delight Baseball ⚾ (9 spots) #32911 -> https://www.cherrycollectables.com.au/products/...
Immaculate Baseball ⚾ (28 spots) #32929 - RT -> https://www.cherrycollectables.com.au/products/...
```

## Requirements

- PowerShell 7.0 or later (`pwsh`)
- Microsoft Edge or Google Chrome (Edge is built into Windows 11; Node.js 20+ and
  `npm install` are optional for Playwright on macOS/Linux/WSL)
- Internet access to `cherrycollectables.com.au`
- Optional: `curl.exe` / `curl` 7.66+ (only used with `-NoBrowser` or if no browser is available)

## Quick Start (Windows)

Run from **PowerShell 7 (`pwsh`)**, not Windows PowerShell 5.1:

```powershell
# Download the script (or run git pull if you cloned the repo)
Invoke-WebRequest "https://raw.githubusercontent.com/Jeff8247/Cherry-Breaks-Links/main/Watch-CherryBreaks-FullDescription-PS7.ps1" -OutFile .\Watch-CherryBreaks-FullDescription-PS7.ps1

# Unblock a script downloaded from the internet, then run
Unblock-File .\Watch-CherryBreaks-FullDescription-PS7.ps1
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday
```

If your execution policy still blocks unsigned scripts, run with:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday
```

## How It Works (Browser-First Fetching)

`Watch-CherryBreaks-FullDescription-PS7.ps1` loads Shopify's `products.json`
(about one request per 250 products, supplying every break's title and variant
availability with no per-product requests) in a **real browser by default** so it
passes Cloudflare managed challenges and avoids stricter CLI/bot throttling:

1. **Node + Playwright (when installed).** If Node.js 20+ is installed and
   `npm install` has been run in the script folder, the script launches an
   embedded single-session Playwright paginator reusing `.browser-profile` cookies.
   On headless Linux/WSL with no Chrome/Edge installed, download Playwright's
   browser via `npx playwright-core install chromium-headless-shell` (and
   `sudo npx playwright install-deps chromium` only if needed).
2. **System Edge/Chrome via CDP (zero install, default on Windows 11).** Otherwise,
   the script drives installed Edge or Chrome over Chrome DevTools Protocol
   (`--remote-debugging-port`) in a single headless session, fetches all collection
   pages without per-page browser restarts, and saves clearance cookies in
   `.browser-profile/native` (falling back to a temporary profile automatically if
   `.browser-profile/native` is locked). On Windows, Edge prints
   `DevTools listening on ws://127.0.0.1:...` to confirm the browser session is active.
3. **HTTP fallback (`curl` / `Invoke-WebRequest`).** Used only when `-NoBrowser` is
   passed or if no supported browser can run (warns once and falls back for that run).

Notes & browser switches:

- Because `products.json` cannot apply the site's day filter, breaks are matched to
  the selected day by the date in their title or URL.
- Spots left are counted from available variants (Shopify's CDN may cache the JSON
  briefly after a spot sells).
- Run with `-Verbose` to inspect skipped items and transport details.
- `-Headed` shows the browser window (works with both system Edge/Chrome and Node + Playwright).
- `-NoBrowser` skips the browser and uses `curl` / `Invoke-WebRequest` directly (faster,
  but more likely to hit Cloudflare 403 challenges or Shopify 429 rate limits).
- `-UseBrowser` is accepted for compatibility (browser mode is already the default).
- On HTTP `403` or `429`, the script halts immediately instead of retrying/cascading
  requests and prints redacted header/body diagnostics. Excessive request volume can
  still trigger `429` even in a browser; keep runs reasonable.
- Legacy `Watch-CherryBreaks-FullDescription.ps1` is also kept in the repo as an
  older Windows PowerShell 5.1 HTML-scraping backup (no `429` handling).

## Usage

Check today's Sydney weekday:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1
```

Check a specific weekday:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday
```

The selected weekday output includes a site search link for that day's live openings, using the next date that falls on that weekday (Sydney time):

```text
Tonights Live Openings (Plz Check Dates) -> https://www.cherrycollectables.com.au/pages/search-results?q=Oct+26+Opening
```

Save results to a text file:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -OutputPath cherry-break-results.txt
```

`-OutputPath` overwrites the target file each run.

### Dailies and Weeklies

Show only daily breaks with spots left for the selected day:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies
```

Show only weekly breaks with spots left. Weeklies are searched from the broader
group-break listings, not only the selected day:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Weeklies
```

Show selected-day Dailies plus broader Weeklies:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Weeklies
```

### YouTube Formatting

Create YouTube-friendly output capped at 200 characters per break line:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -YouTube
```

When `-YouTube` is used, only the break description is shortened. The spots,
sport emoji, break number, allocation suffix, and full product URL are kept.

## Twitch Chat

### Create a Twitch OAuth Token

This script sends chat through Twitch IRC, so it needs a Twitch User Access
Token for the account that will post the messages.

Recommended method:

1. Install the official Twitch CLI from
   https://dev.twitch.tv/docs/cli.
2. Log in with the Twitch account you want messages to come from.
3. Generate a user token with the IRC chat scopes:

```powershell
twitch token -u -s "chat:read chat:edit"
```

The CLI opens a browser and asks you to authorize the scopes. Copy the
`User Access Token` value it prints.

Alternative method:

Use any Twitch OAuth token generator that lets you choose scopes, log in as
the Twitch account you want messages to come from, and select:

```text
chat:read
chat:edit
```

Only use token generators you trust. The token can send chat as that Twitch
account, so treat it like a password.

Create a `.env` file beside the script:

```text
TWITCH_CHANNEL=yourchannel
TWITCH_USER=yourusername
TWITCH_OAUTH_TOKEN=oauth:your_token_here
```

`TWITCH_USER` can be your normal Twitch account or a separate bot account.
The token needs Twitch chat `chat:read` and `chat:edit` scopes. Treat it like
a password. The local `.env` file is ignored by git.

Send only daily breaks with spots left to Twitch chat:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Twitch
```

Send daily and weekly breaks with spots left to Twitch chat:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Weeklies -Twitch
```

Send only weekly breaks with spots left to Twitch chat:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Weeklies -Twitch
```

If `-Twitch` is used without `-Dailies` or `-Weeklies`, Twitch posting keeps
the legacy daily-only behavior.

The script sends one chat message per matching break over TLS-verified Twitch IRC
(`irc.chat.twitch.tv:6697`) and waits 3 seconds between messages by default. You can
change that delay:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Weeklies -Twitch -TwitchMessageDelaySeconds 5
```

The Twitch sender prints whether Twitch IRC accepted the login and confirmed
the channel join before submitting messages. For raw IRC diagnostics, rerun
with `-Verbose`; the OAuth token is redacted in verbose output:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Twitch -Verbose
```

You can also pass Twitch settings directly if needed:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 `
  -Day Monday `
  -Dailies `
  -Weeklies `
  -Twitch `
  -TwitchChannel yourchannel `
  -TwitchUser yourusername `
  -TwitchOAuthToken $env:TWITCH_OAUTH_TOKEN
```
