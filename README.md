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
curl. No header tweak gets past it, and it affects every path, including
`products.json` and the sitemaps. It is separate from the 429 rate limit, which a
browser does not avoid.

When the script gets a 403, it retries that request in a real browser. Nothing has
to be installed on Windows 11:

1. **System Edge/Chrome (default, no install).** The script runs the Edge or Chrome
   already on the machine headless (`--dump-dom`), waits for the challenge to finish,
   and reads the JSON from the page. A profile is kept in `.browser-profile/native`
   beside the script so Cloudflare's clearance cookie is reused. Verified working on
   Windows 11 with Edge.
2. **Node + Playwright (optional).** If Node.js 18+ is installed and `npm install` has
   been run in the script folder, `browser-fetch.mjs` is used instead. It also works
   on macOS and Linux (on Linux/WSL run `sudo npx playwright install-deps chromium`
   first), and it supports `-Headed`.

Switches:

- `-UseBrowser` sends every request through the browser instead of curl. It is slower
  and not needed for normal runs; without it the browser is only used after a 403.
- `-NoBrowser` disables the fallback.
- `-Headed` shows the window (Node + Playwright route only).

If the browser cannot get through, the error says why (for example, a Cloudflare
page title, or the JSON it received instead of `products`).

Please keep request volume low and check Cherry Collectables' terms; asking them for
an official feed or allowlisting is the most reliable fix.

### Windows: "file is not digitally signed"

A script downloaded from the internet is blocked by the default execution policy.
Unblock it once, or bypass for a single run:

```powershell
Unblock-File .\Watch-CherryBreaks-FullDescription-PS7.ps1
pwsh -ExecutionPolicy Bypass -File .\Watch-CherryBreaks-FullDescription-PS7.ps1
```

Run it from PowerShell 7 (`pwsh`), not Windows PowerShell 5.1.

## Requirements

- PowerShell 7.0 or later (`pwsh`)
- Internet access to `cherrycollectables.com.au`
- Recommended: `curl.exe` / `curl` 7.66 or newer (included with Windows 10/11 and Linux)
- For the Cloudflare browser fallback: Microsoft Edge or Google Chrome (Edge is built into Windows 11). Node.js 18+ and `npm install` are optional.

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
