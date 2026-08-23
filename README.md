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
Pokemon Pitch Black (1) (7 spots) #32915 -> https://www.cherrycollectables.com.au/products/...
Topps Chrome Delight Baseball (1) ⚾ (9 spots) #32911 -> https://www.cherrycollectables.com.au/products/...
Immaculate Baseball (1) ⚾ (28 spots) #32929 - RT -> https://www.cherrycollectables.com.au/products/...
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Internet access to `cherrycollectables.com.au`

## Usage

Check today's Sydney weekday:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1
```

Check a specific weekday:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday
```

The selected weekday output includes that day's live openings collection link:

```text
Tonights Live Openings (Plz Check Dates) -> https://www.cherrycollectables.com.au/collections/Monday
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
