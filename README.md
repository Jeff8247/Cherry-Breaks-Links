# Cherry Breaks Links

PowerShell script for checking Cherry Collectables group breaks and printing
clean, ready-to-share break lines.

## What It Does

- Checks Cherry Collectables group breaks for a selected weekday.
- Uses Sydney time when deciding today's date.
- Prints each break with description, sport emoji, spots left, break number,
  allocation suffix where useful, and product URL.
- Can produce YouTube-friendly break lines capped at 200 characters while
  keeping spots, break number, allocation suffix, and product URL intact.
- Prints a selected day's live openings collection link when `-Day` is used.
- Sorts results from least spots left to most spots left.
- Cleans noisy title metadata such as dates, `Team Based`, `Random Type`,
  `Random Character`, duplicated separators, and Cherry's `・` separator.

Example output:

```text
Pokemon Pitch Black 1 Box Opening (7 spots) #32915 -> https://www.cherrycollectables.com.au/products/...
Topps Chrome Delight Baseball 1 Box Opening ⚾ (9 spots) #32911 -> https://www.cherrycollectables.com.au/products/...
Immaculate Baseball 1 Box Opening ⚾ (28 spots) #32929 - RT -> https://www.cherrycollectables.com.au/products/...
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

Create YouTube-friendly output capped at 200 characters per break line:

```powershell
.\Watch-CherryBreaks-FullDescription.ps1 -Day Monday -YouTube
```

When `-YouTube` is used, only the break description is shortened. The spots,
sport emoji, break number, allocation suffix, and full product URL are kept.
