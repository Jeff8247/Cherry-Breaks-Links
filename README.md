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

## Versions

Two copies of the script are kept side by side. They take the same parameters
and produce the same output, and both read the same `.env` file.

- `Watch-CherryBreaks-FullDescription.ps1` - the original. Loads each product
  one request at a time.
- `Watch-CherryBreaks-FullDescription-v2.ps1` - faster. Before checking
  products, it loads all product data at once with a single
  `curl.exe --parallel` call (6 at a time). It also turns off the slow
  PowerShell progress bar and reuses the collection page between listings.
  Typical runs dropped from about 22-28 seconds to about 5-8 seconds in
  testing on Windows PowerShell 5.1.

v2 notes:

- It needs `curl.exe` 7.66 or newer (`curl.exe --version`), which current
  Windows 10 and 11 include. If curl is missing or too old, v2 quietly falls
  back to loading products one at a time, the same as the original.
- It uses curl rather than PowerShell's own web requests because the site
  rate limits (HTTP 429) bursts of PowerShell requests but not curl.
- Run with `-Verbose` to see how many products were prefetched, for example
  `Prefetched 44 of 44 product JSON file(s)`.
- Use the original script if v2 ever misbehaves.

Every example below works with either script; swap in the `-v2` filename to
use the faster one.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Internet access to `cherrycollectables.com.au`
- v2 only: `curl.exe` 7.66 or newer (included with current Windows 10/11)

## Usage

Check today's Sydney weekday:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1
```

Check a specific weekday:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday
```

The selected weekday output includes a site search link for that day's live openings, using the next date that falls on that weekday (Sydney time):

```text
Tonights Live Openings (Plz Check Dates) -> https://www.cherrycollectables.com.au/pages/search-results?q=Oct+26+Opening
```

Save results to a text file:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -OutputPath cherry-break-results.txt
```

`-OutputPath` overwrites the target file each run.

### Dailies and Weeklies

Show only daily breaks with spots left for the selected day:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies
```

Show only weekly breaks with spots left. Weeklies are searched from the broader
group-break listings, not only the selected day:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Weeklies
```

Show selected-day Dailies plus broader Weeklies:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies -Weeklies
```

Create YouTube-friendly output capped at 200 characters per break line:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -YouTube
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
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies -Twitch
```

Send daily and weekly breaks with spots left to Twitch chat:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies -Weeklies -Twitch
```

Send only weekly breaks with spots left to Twitch chat:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Weeklies -Twitch
```

If `-Twitch` is used without `-Dailies` or `-Weeklies`, Twitch posting keeps
the legacy daily-only behavior.

The script sends one chat message per matching break and waits 2 seconds
between messages by default. You can change that delay:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies -Weeklies -Twitch -TwitchMessageDelaySeconds 3
```

The Twitch sender prints whether Twitch IRC accepted the login and confirmed
the channel join before submitting messages. For raw IRC diagnostics, rerun
with `-Verbose`; the OAuth token is redacted in verbose output:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -Dailies -Twitch -Verbose
```

You can also pass Twitch settings directly if needed:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 `
  -Day Monday `
  -Dailies `
  -Weeklies `
  -Twitch `
  -TwitchChannel yourchannel `
  -TwitchUser yourusername `
  -TwitchOAuthToken $env:TWITCH_OAUTH_TOKEN
```
