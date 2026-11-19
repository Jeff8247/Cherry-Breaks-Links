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
  `Sluggerz`, and `Amigos`, including loose singular/plural variants.
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

## Script

`Watch-CherryBreaks-FullDescription-PS7.ps1` is the recommended script for PowerShell 7+. It
loads the collection from Shopify's `products.json` first (about one request per
collection, up to 250 products each), which also supplies every product's title
and availability, so it needs no per-product requests. It uses native curl and
lightweight HTTP requests to avoid Cloudflare bot detection and rate limits.

The original `Watch-CherryBreaks-FullDescription.ps1` is also kept for Windows PowerShell 5.1. It uses the
HTML collection pages and has no 429 handling.

- Because `products.json` cannot apply the site's day filter, breaks are matched
  to the day by the date in their title or URL.
- Spots left are counted from available variants. Shopify's CDN may cache the
  JSON briefly, so a spot that just sold can take a moment to show.
- Run with `-Verbose` to see diagnostic information such as which source was used.
- It detects HTTP 429 (rate limited) and 403 (blocked). It halts immediately instead
  of cascading into more requests, and advises how long to wait so the IP block can reset.
- On a 403 or 429 it prints block diagnostics: the status line, key headers
  (`cf-mitigated`, `cf-ray`, `server`, `retry-after`), a body snippet, and the
  likely cause (for example a Cloudflare managed challenge). Cookie values are redacted.

## Cloudflare Challenges and the Browser Fallback

Cherry Collectables sits behind Cloudflare, which intermittently serves a managed
challenge (`HTTP 403`, `cf-mitigated: challenge`) to non-browser clients such as
curl. When that happens, no header tweak will get past it. It affects every path,
including `products.json` and the sitemaps.

To handle this, the script falls back to a real browser on a 403. It runs
`browser-fetch.mjs` (Node.js + Playwright), which loads the URL in Chrome, Edge or
Chromium, waits for the challenge to complete, and returns the page text. The
fallback works on Windows, macOS and Linux and keeps its browser profile in
`.browser-profile/` so the Cloudflare clearance cookie is reused between runs.

Setup (only needed for the fallback):

```powershell
npm install
```

- **Windows/macOS:** an installed Chrome or Edge is used automatically; otherwise run
  `npx playwright install chromium`.
- **Linux/WSL:** Chromium needs system libraries. Install them once with
  `sudo npx playwright install-deps chromium` (plus `npx playwright install chromium`
  if no browser is installed). Without them the script prints a warning and continues
  to fail with the normal 403 error.
- `-Headed` shows the browser window, which is more reliable against Cloudflare.
- `-NoBrowser` disables the fallback entirely.

Status: the fallback has not yet been tested against a live challenge, because
Cloudflare stopped challenging the script's plain requests while it was being built.
This is automation of a site's bot protection, so check Cherry Collectables' terms,
keep request volume low, and consider asking them for an official feed or allowlisting.

## Requirements

- PowerShell 7.0 or later (`pwsh`)
- Internet access to `cherrycollectables.com.au`
- Recommended: `curl.exe` / `curl` 7.66 or newer (included with Windows 10/11 and Linux)
- Optional, for the Cloudflare browser fallback: Node.js 18+ and `npm install`

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

The script sends one chat message per matching break and waits 2 seconds
between messages by default. You can change that delay:

```powershell
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Monday -Dailies -Weeklies -Twitch -TwitchMessageDelaySeconds 3
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
