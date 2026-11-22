#requires -Version 7.0

<#
Checks Cherry Collectables group breaks and prints full-description
lines in this format:

DESCRIPTION | SPORT EMOJI | SPOTS | BREAK NUMBER | ALLOCATION | -> URL

By default, the script checks today's Sydney day. Use -Day to check the
next matching weekday instead.

Requires PowerShell 7.0 or later. Uses Shopify products.json via a real
browser by default (Node + Playwright when installed, otherwise system
Edge/Chrome headless) to pass Cloudflare challenges, or curl /
Invoke-WebRequest when -NoBrowser is specified.

Examples:

.\Watch-CherryBreaks-FullDescription-PS7.ps1
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday -OutputPath cherry-break-results.txt
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday -YouTube
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday -Dailies -Twitch
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday -Dailies -Weeklies -Twitch
.\Watch-CherryBreaks-FullDescription-PS7.ps1 -Day Friday -NoBrowser

-OutputPath overwrites the text file every run.
#>

[CmdletBinding()]
param(
    [ValidateSet(
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
    )]
    [string]$Day,

    [string]$OutputPath,

    [switch]$YouTube,

    [switch]$Dailies,

    [switch]$Weeklies,

    [switch]$Twitch,

    [string]$TwitchChannel,

    [Alias('TwitchBotUser')]
    [string]$TwitchUser,

    [string]$TwitchOAuthToken,

    [ValidateRange(1, 30)]
    [int]$TwitchMessageDelaySeconds = 3,

    [string]$EnvPath = '.env',

    # Use curl / Invoke-WebRequest only; do not use the real browser (the default is the browser)
    [switch]$NoBrowser,

    # Kept for compatibility: the real browser is now the default for every request
    [switch]$UseBrowser,

    # Show the browser window when the Playwright browser runs (more reliable against Cloudflare)
    [switch]$Headed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DayWasExplicitlyRequested = $PSBoundParameters.ContainsKey('Day')

#region Constants & Precompiled Rules

$script:BaseUrl = 'https://www.cherrycollectables.com.au'
$script:CollectionPath = '/collections/card-breaks'
$script:ProductsJsonBaseUrl = "$($script:BaseUrl)$($script:CollectionPath)/products.json?limit=250"
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$script:Headers = @{
    'User-Agent' = 'Mozilla/5.0 (compatible; CherryBreakWatcher/1.0)'
    'Accept'     = 'application/json, */*'
}

$script:SydneyTimeZone = try {
    [TimeZoneInfo]::FindSystemTimeZoneById('Australia/Sydney')
}
catch {
    [TimeZoneInfo]::FindSystemTimeZoneById('AUS Eastern Standard Time')
}

$script:SydneyNow = [TimeZoneInfo]::ConvertTimeFromUtc(
    [datetime]::UtcNow,
    $script:SydneyTimeZone
)

$script:MonthNumbers = @{
    jan       = 1; january   = 1
    feb       = 2; february  = 2
    mar       = 3; march     = 3
    apr       = 4; april     = 4
    may       = 5
    jun       = 6; june      = 6
    jul       = 7; july      = 7
    aug       = 8; august    = 8
    sep       = 9; sept      = 9; september = 9
    oct       = 10; october  = 10
    nov       = 11; november = 11
    dec       = 12; december = 12
}

$script:RegexIgnoreCaseCompiled = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Compiled
$script:RegexCompiled = [System.Text.RegularExpressions.RegexOptions]::Compiled

$monthsRegexPart = 'Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?'
$timeRegexPart = '\d{1,2}(?::\d{2})?\s*(?:am|pm)'
$middleDotEscaped = [regex]::Escape([string][char]0x30FB)
$separatorChars = '\-\|' + $middleDotEscaped +
    [regex]::Escape([string][char]0x2013) +
    [regex]::Escape([string][char]0x2014)

$script:MonthDayRegex = [regex]::new(
    "(?:^|[-_/\s(])(?<month>$monthsRegexPart)[-_/\s]+(?<day>\d{1,2})(?:st|nd|rd|th)?(?:[-_/\s),]|$)",
    $script:RegexIgnoreCaseCompiled
)
$script:DayMonthRegex = [regex]::new(
    "(?:^|[-_/\s(])(?<day>\d{1,2})(?:st|nd|rd|th)?[-_/\s]+(?:of[-_/\s]+)?(?<month>$monthsRegexPart)(?:[-_/\s),]|$)",
    $script:RegexIgnoreCaseCompiled
)

# "Lil Punterz" is a daily break; standalone "Punterz" is treated as weekly.
$script:DailyBreakNameRegex = [regex]::new(
    '\b(?<lil>Lil\s+)?(?<name>Punterz|Teamz|Squadz|Derby|Slapperz)\b',
    $script:RegexIgnoreCaseCompiled
)
$script:WeeklyBreakNameRegex = [regex]::new(
    '\b(?<name>Machos?|Spenda(?:s|z)?|(?<!\bLil\s+)Punterz?|Slugger(?:s|z)?|Amigos?)\b',
    $script:RegexIgnoreCaseCompiled
)
$script:BreakNumberRegex = [regex]::new('#(?<number>\d+)', $script:RegexCompiled)

$script:DateRemovalRegexes = @(
    [regex]::new('\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b', $script:RegexIgnoreCaseCompiled)
    [regex]::new("\(\s*(?:(?:$monthsRegexPart)\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:$monthsRegexPart))(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$timeRegexPart)?\s*\)", $script:RegexIgnoreCaseCompiled)
    [regex]::new("\b(?:$monthsRegexPart)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$timeRegexPart)?\b", $script:RegexIgnoreCaseCompiled)
    [regex]::new("\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:$monthsRegexPart)(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$timeRegexPart)?\b", $script:RegexIgnoreCaseCompiled)
    [regex]::new('(?<!\d)20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}(?!\d)', $script:RegexCompiled)
    [regex]::new('(?<!\d)\d{1,2}[-/.]\d{1,2}(?:[-/.](?:20)?\d{2})?(?!\d)', $script:RegexCompiled)
    [regex]::new('\b20\d{2}(?:[-/]\d{2,4})?\b', $script:RegexIgnoreCaseCompiled)
)

$script:AllocationRules = @(
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Teams?|RT)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RT' }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Wrestlers?|RW)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RW' }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Spots?|RS)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RS' }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Colou?rs?|RC)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RC' }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Players?|RP)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RP' }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Random\s+Packs?|RPk)\b', $script:RegexIgnoreCaseCompiled); Suffix = ' - RPk' }
)

$script:DescriptionStripRegex = [regex]::new(
    '#\d+|\b(?:Wrestler\s+Team\s+Based|Team\s+Based|Pick\s+Your\s+Wrestlers?|PYW|Pick\s+Your\s+Players?|PYP|Pick\s+Your\s+Teams?|PYT|Random\s+Teams?|RT|Random\s+Wrestlers?|RW|Random\s+Spots?|RS|Random\s+Colou?rs?|RC|Random\s+Players?|RP|Random\s+Packs?|RPk|Random\s+Types?|Types?|Random\s+Characters?|Random\s+Wreslet|Opening)\b',
    $script:RegexIgnoreCaseCompiled
)
$script:SingleBoxRegex = [regex]::new('\b1\s*-?\s*Box(?:es)?\b', $script:RegexIgnoreCaseCompiled)
$script:MultiBoxRegex = [regex]::new('\b(?<count>\d+)\s*-?\s*Box(?:es)?\b', $script:RegexIgnoreCaseCompiled)
$script:MiddleDotRegex = [regex]::new("\s*$middleDotEscaped\s*", $script:RegexCompiled)
$script:TrailingSeparatorRegex = [regex]::new("[\s\p{Zs}]*[$separatorChars]+(?:[\s\p{Zs}]*[$separatorChars]+)*[\s\p{Zs}]*$", $script:RegexCompiled)
$script:LeadingSeparatorRegex = [regex]::new("^[\s\p{Zs}]*[$separatorChars]+(?:[\s\p{Zs}]*[$separatorChars]+)*[\s\p{Zs}]*", $script:RegexCompiled)
$script:MultiWhitespaceRegex = [regex]::new('\s+', $script:RegexCompiled)

$script:NormalizePresidentRegex = [regex]::new("\s+[$separatorChars]+\s*$middleDotEscaped\s*(?=Random\s+President\b)", $script:RegexCompiled)
$script:NormalizeSepDotRegex = [regex]::new("\s+[$separatorChars]+\s*$middleDotEscaped\s*", $script:RegexCompiled)
$script:NormalizeBeforeSpotsRegex = [regex]::new("\s+[$separatorChars]+\s+(?=(?:\S+\s+)?\((?:\?|\d+)\s+spots?(?:\s+left)?\))", $script:RegexCompiled)
$script:MultiSpaceRegex = [regex]::new('\s{2,}', $script:RegexCompiled)

$emojiFootball = [char]::ConvertFromUtf32(0x1F3C8)
$emojiBasketball = [char]::ConvertFromUtf32(0x1F3C0)
$emojiBaseball = [char]::ConvertFromUtf32(0x26BE)
$emojiHockey = [char]::ConvertFromUtf32(0x1F3D2)
$emojiSoccer = [char]::ConvertFromUtf32(0x26BD)
$emojiTennis = [char]::ConvertFromUtf32(0x1F3BE)
$emojiWrestling = [char]::ConvertFromUtf32(0x1F93C) + [char]::ConvertFromUtf32(0x200D) +
    [char]::ConvertFromUtf32(0x2642) + [char]::ConvertFromUtf32(0xFE0F)

# Order matters: daily names take precedence, and soccer precedes Topps/MLB/Bowman.
$script:SportEmojiRules = @(
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Lil\s+)?(?:Punterz|Squadz)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiFootball }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Lil\s+)?Teamz\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiBasketball }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Lil\s+)?Derby\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiBaseball }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Lil\s+)?Slapperz\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiHockey }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Soccer|EPL|UCL|UEFA|FIFA|Premier League|Champions League|La Liga|LaLiga|Bundesliga|Serie A|Ligue 1|MLS|World Cup|Euro 20\d{2})\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiSoccer }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:NBA|Basketball)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiBasketball }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:NFL|American Football|Gridiron)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiFootball }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:NHL|Hockey)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiHockey }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:Tennis|ATP|WTA)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiTennis }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:WWE|AEW|MLW|Wrestling|Wrestler|Wrestlers)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiWrestling }
    [pscustomobject]@{ Regex = [regex]::new('\b(?:MLB|Baseball|Bowman)\b', $script:RegexIgnoreCaseCompiled); Emoji = $emojiBaseball }
)

$script:CachedCurlPath = $null
$script:CurlPathResolved = $false
$script:CachedNodePath = $null
$script:NodePathResolved = $false
$script:CachedBrowserPath = $null
$script:BrowserPathResolved = $false

#endregion

#region Configuration & .env Helpers

function Resolve-ScriptRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $PSScriptRoot $Path
}

function ConvertFrom-DotEnvValue {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    $trimmed = $Value.Trim()

    if ($trimmed.Length -ge 2) {
        $first = $trimmed[0]
        $last = $trimmed[$trimmed.Length - 1]

        if (($first -eq '"' -and $last -eq '"') -or
            ($first -eq "'" -and $last -eq "'")) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }

    return $trimmed
}

function Import-DotEnvFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-ScriptRelativePath -Path $Path
    $values = @{}

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        $trimmedLine = $line.Trim()

        if (-not $trimmedLine -or $trimmedLine.StartsWith('#')) {
            continue
        }

        $match = [regex]::Match(
            $trimmedLine,
            '^\s*(?:export\s+)?(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)\s*$'
        )

        if (-not $match.Success) {
            continue
        }

        $values[$match.Groups['name'].Value] = ConvertFrom-DotEnvValue -Value $match.Groups['value'].Value
    }

    return $values
}

function Get-ConfigValue {
    param(
        [AllowEmptyString()]
        [string]$CurrentValue,

        [Parameter(Mandatory)]
        [hashtable]$DotEnvValues,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($CurrentValue) {
        return $CurrentValue
    }

    foreach ($name in $Names) {
        if ($DotEnvValues.ContainsKey($name) -and $DotEnvValues[$name]) {
            return [string]$DotEnvValues[$name]
        }

        $environmentValue = [Environment]::GetEnvironmentVariable($name)
        if ($environmentValue) {
            return $environmentValue
        }
    }

    return $CurrentValue
}

$DotEnvValues = Import-DotEnvFile -Path $EnvPath
$TwitchChannel = Get-ConfigValue -CurrentValue $TwitchChannel -DotEnvValues $DotEnvValues -Names @('TWITCH_CHANNEL')
$TwitchUser = Get-ConfigValue -CurrentValue $TwitchUser -DotEnvValues $DotEnvValues -Names @('TWITCH_USER', 'TWITCH_BOT_USER')
$TwitchOAuthToken = Get-ConfigValue -CurrentValue $TwitchOAuthToken -DotEnvValues $DotEnvValues -Names @('TWITCH_OAUTH_TOKEN')

#endregion

#region Process, Diagnostics & Error Helpers

function New-CherryRequestException {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('RateLimited', 'Blocked', 'BrowserUnavailable', 'HttpError')]
        [string]$Kind,

        [int]$StatusCode = 0
    )

    $ex = [System.Exception]::new($Message)
    $ex.Data['Kind'] = $Kind
    $ex.Data['StatusCode'] = $StatusCode
    return $ex
}

function Get-ExceptionKind {
    param(
        [System.Exception]$Exception
    )

    if ($Exception -and $Exception.Data -and $Exception.Data.Contains('Kind')) {
        return [string]$Exception.Data['Kind']
    }

    return $null
}

function Get-BodySnippet {
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaxLength = 300
    )

    if (-not $Text) {
        return ''
    }

    $snippet = ($Text -replace '\s+', ' ').Trim()
    if ($snippet.Length -gt $MaxLength) {
        return $snippet.Substring(0, $MaxLength) + '...'
    }

    return $snippet
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [AllowNull()]
        [string]$StandardInput = $null,

        [ValidateRange(1000, 600000)]
        [int]$TimeoutMilliseconds = 60000
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding = $script:Utf8NoBom

    if ($null -ne $StandardInput) {
        $psi.RedirectStandardInput = $true
    }

    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Failed to start process '$FilePath'."
        }

        if ($null -ne $StandardInput) {
            $inputBytes = $script:Utf8NoBom.GetBytes($StandardInput)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
            $process.StandardInput.Close()
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill($true)
            }
            catch {
                try { $process.Kill() } catch { }
            }
            throw "Process '$FilePath' timed out after $([int]($TimeoutMilliseconds / 1000)) seconds."
        }

        # WaitForExit(int) can return before async stream buffers finish flushing.
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-NativeCurlPath {
    if (-not $script:CurlPathResolved) {
        $cmd = @(
            Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
            Get-Command curl -CommandType Application -ErrorAction SilentlyContinue
        ) | Select-Object -First 1

        $script:CachedCurlPath = if ($cmd) { $cmd.Source } else { $null }
        $script:CurlPathResolved = $true
    }

    return $script:CachedCurlPath
}

function Get-NodePath {
    if (-not $script:NodePathResolved) {
        $cmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:CachedNodePath = if ($cmd) { $cmd.Source } else { $null }
        $script:NodePathResolved = $true
    }

    return $script:CachedNodePath
}

function Get-NativeBrowserPath {
    if ($script:BrowserPathResolved) {
        return $script:CachedBrowserPath
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) {
            $candidates.Add((Join-Path $root 'Microsoft\Edge\Application\msedge.exe'))
            $candidates.Add((Join-Path $root 'Google\Chrome\Application\chrome.exe'))
        }
    }
    $candidates.Add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    $candidates.Add('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge')

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $script:CachedBrowserPath = $path
            $script:BrowserPathResolved = $true
            return $path
        }
    }

    foreach ($name in 'microsoft-edge', 'google-chrome', 'chromium', 'chromium-browser') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $script:CachedBrowserPath = $cmd.Source
            $script:BrowserPathResolved = $true
            return $cmd.Source
        }
    }

    $script:BrowserPathResolved = $true
    return $null
}

function Get-CherryBlockDiagnostics {
    # Summarises a blocked/rate-limited response so we can tell a Cloudflare
    # challenge from a Shopify rate limit or a plain WAF rule.
    param(
        [AllowNull()]
        [string]$RawHeaders,

        [AllowNull()]
        [string]$Body
    )

    $interesting = 'server|cf-ray|cf-mitigated|cf-cache-status|content-type|retry-after|x-shopify-stage|x-request-id|x-sorting-hat|set-cookie'
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($RawHeaders) {
        # curl --dump-header may hold several blocks (redirects); keep the last one.
        $blocks = @($RawHeaders -split '(?:\r?\n){2,}' | Where-Object { $_.Trim() })
        if ($blocks.Count -gt 0) {
            foreach ($line in ($blocks[-1] -split '\r?\n')) {
                if ($line -match '^HTTP/' -or $line -match "^(?i)($interesting):") {
                    if ($line -match '^(?i)set-cookie:\s*([^=]+)=') {
                        $line = "set-cookie: $($Matches[1])=<redacted>"
                    }
                    $lines.Add("    $line")
                }
            }
        }
    }

    $hint = ''
    if ($RawHeaders -match '(?im)^cf-mitigated:\s*challenge') {
        $hint = 'Cloudflare managed challenge (needs a real browser).'
    }
    elseif ($RawHeaders -match '(?im)^server:\s*cloudflare' -and $Body -match 'Just a moment|cf-chl|challenge-platform') {
        $hint = 'Cloudflare interstitial challenge page.'
    }
    elseif ($RawHeaders -match '(?im)^server:\s*cloudflare' -and $Body -match 'Attention Required|Sorry, you have been blocked') {
        $hint = 'Cloudflare WAF block page.'
    }
    elseif ($RawHeaders -match '(?im)^x-shopify-stage|^x-sorting-hat') {
        $hint = 'Served by Shopify directly (not a Cloudflare challenge).'
    }

    $snippet = Get-BodySnippet -Text $Body
    $out = [System.Text.StringBuilder]::new()
    [void]$out.AppendLine()
    [void]$out.AppendLine('  --- Block diagnostics ---')
    if ($lines.Count -gt 0) { [void]$out.AppendLine(($lines -join [Environment]::NewLine)) }
    if ($hint) { [void]$out.AppendLine("  Likely cause: $hint") }
    if ($snippet) { [void]$out.AppendLine("  Body: $snippet") }
    return $out.ToString().TrimEnd()
}

#endregion

#region Collection Fetching & JsonDocument Parsing

function ConvertFrom-ProductsJson {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$JsonText,

        [Parameter(Mandatory)]
        [string]$SourceUrl
    )

    $doc = $null
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($JsonText)
    }
    catch {
        $snippet = Get-BodySnippet -Text $JsonText
        throw (New-CherryRequestException -Kind 'HttpError' -Message "Unexpected non-JSON response from '$SourceUrl'. Content starts: $snippet")
    }

    try {
        $root = $doc.RootElement
        $productsElement = [System.Text.Json.JsonElement]::new()

        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            -not $root.TryGetProperty('products', [ref]$productsElement) -or
            $productsElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
            $snippet = Get-BodySnippet -Text $JsonText
            throw (New-CherryRequestException -Kind 'HttpError' -Message "Unexpected response from '$SourceUrl' (no 'products' property). Content starts: $snippet")
        }

        $products = [System.Collections.Generic.List[object]]::new()
        $rawCount = 0
        $prop = [System.Text.Json.JsonElement]::new()
        $variantsEl = [System.Text.Json.JsonElement]::new()

        foreach ($prodEl in $productsElement.EnumerateArray()) {
            $rawCount++
            if ($prodEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                continue
            }

            if (-not $prodEl.TryGetProperty('handle', [ref]$prop) -or
                $prop.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                continue
            }

            $handle = $prop.GetString()
            if (-not $handle) {
                continue
            }

            $title = ''
            if ($prodEl.TryGetProperty('title', [ref]$prop) -and
                $prop.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                $title = $prop.GetString()
            }

            $spotsLeft = 0
            if ($prodEl.TryGetProperty('variants', [ref]$variantsEl) -and
                $variantsEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                $availableCount = 0
                $inventorySum = 0
                $hasInventory = $false

                foreach ($varEl in $variantsEl.EnumerateArray()) {
                    if ($varEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                        continue
                    }

                    if (-not $varEl.TryGetProperty('available', [ref]$prop) -or
                        $prop.ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
                        continue
                    }

                    $availableCount++
                    if ($varEl.TryGetProperty('inventory_quantity', [ref]$prop) -and
                        $prop.ValueKind -eq [System.Text.Json.JsonValueKind]::Number) {
                        $qty = 0
                        if ($prop.TryGetInt32([ref]$qty)) {
                            $hasInventory = $true
                            $inventorySum += $qty
                        }
                    }
                }

                $spotsLeft = if ($availableCount -eq 0) {
                    0
                }
                elseif ($hasInventory) {
                    $inventorySum
                }
                else {
                    $availableCount
                }
            }

            $products.Add([pscustomobject]@{
                Handle    = $handle
                Title     = $title
                Url       = "$($script:BaseUrl)/products/$handle"
                SpotsLeft = $spotsLeft
            })
        }

        return [pscustomobject]@{
            RawCount = $rawCount
            Products = $products.ToArray()
        }
    }
    finally {
        $doc.Dispose()
    }
}

$script:PlaywrightPaginatorScript = @'
import { pathToFileURL } from 'node:url';

const [playwrightEntry, baseUrl, profileDir, maxPagesRaw, timeoutSecRaw, ...rest] = process.argv.slice(2);
const maxPages = Number(maxPagesRaw) || 10;
const timeoutMs = (Number(timeoutSecRaw) || 60) * 1000;
const headed = rest.includes('--headed');

// Never call process.exit() after writing to stdout: on a pipe the write is async on
// POSIX and exit() truncates large payloads. Set exitCode and let the process drain.
function emit(result, code) {
  process.stdout.write(JSON.stringify(result));
  process.exitCode = code;
}

const isChallenge = (title) => /Verifying|Just a moment|Attention Required/i.test(title || '');

function snippet(text, limit = 300) {
  const clean = String(text || '').replace(/\s+/g, ' ').trim();
  return clean.length > limit ? clean.slice(0, limit) + '...' : clean;
}

function countSpots(product) {
  const variants = Array.isArray(product?.variants) ? product.variants : [];
  const available = variants.filter((v) => v && v.available === true);
  if (available.length === 0) return 0;

  let spots = 0;
  let hasInventory = false;
  for (const v of available) {
    if (typeof v.inventory_quantity === 'number' && Number.isFinite(v.inventory_quantity)) {
      hasInventory = true;
      spots += Math.trunc(v.inventory_quantity);
    }
  }
  return hasInventory ? spots : available.length;
}

async function launch(chromium) {
  const base = { headless: !headed, args: ['--no-sandbox'] };
  const attempts = [{ channel: 'chrome' }, { channel: 'msedge' }, {}];
  let lastError;
  for (const extra of attempts) {
    try {
      return await chromium.launchPersistentContext(profileDir, { ...base, ...extra });
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}

async function loadViaNavigation(page, url) {
  const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
  let status = response ? response.status() : 0;

  const deadline = Date.now() + timeoutMs;
  let challenged = isChallenge(await page.title().catch(() => ''));
  while (challenged && Date.now() < deadline) {
    await page.waitForTimeout(2000);
    challenged = isChallenge(await page.title().catch(() => ''));
  }

  if (!challenged && status === 403) {
    const again = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    status = again ? again.status() : status;
  }

  const body = challenged ? '' : await page.evaluate(() => (document.body ? document.body.innerText : ''));
  const title = await page.title().catch(() => '(none)');
  return { status, body, challenged, title };
}

function parseProductsPayload(body, url, title) {
  const trimmed = String(body || '').trimStart();
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    const looksLikeJson = trimmed.startsWith('{') || trimmed.startsWith('[');
    return {
      ok: false,
      error: looksLikeJson
        ? `Browser fallback failed: '${url}' returned invalid JSON: ${snippet(body)}`
        : `Browser fallback failed: '${url}' did not return JSON. Page title: '${title || '(none)'}'. Text: ${snippet(body)}`
    };
  }

  if (!parsed || !Array.isArray(parsed.products)) {
    return {
      ok: false,
      error: `Browser fallback failed: '${url}' returned JSON without a 'products' array: ${snippet(body)}`
    };
  }

  return { ok: true, products: parsed.products };
}

let context;
try {
  const pw = await import(pathToFileURL(playwrightEntry).href);
  try {
    context = await launch(pw.chromium);
  } catch (launchErr) {
    emit({
      status: 0,
      challenged: false,
      browserUnavailable: true,
      products: [],
      error: String(launchErr?.message ?? launchErr).split('\n')[0]
    }, 2);
  }

  if (context) {
    const page = context.pages()[0] ?? (await context.newPage());
    const allProducts = [];

    for (let pageNum = 1; pageNum <= maxPages; pageNum++) {
      const pageUrl = `${baseUrl}&page=${pageNum}`;
      let result;

      if (pageNum === 1) {
        result = await loadViaNavigation(page, pageUrl);
      } else {
        const fetched = await page.evaluate(async (u) => {
          const r = await fetch(u, { credentials: 'include', headers: { Accept: 'application/json' } });
          return { status: r.status, text: await r.text() };
        }, pageUrl);

        if (fetched.status === 403) {
          result = await loadViaNavigation(page, pageUrl);
        } else {
          result = { status: fetched.status, body: fetched.text, challenged: false, title: '(fetch)' };
        }
      }

      if (result.challenged) {
        emit({
          status: result.status || 403,
          challenged: true,
          products: [],
          error: `Access blocked (HTTP 403) by '${pageUrl}'. The browser could not pass the Cloudflare challenge; try -Headed.`
        }, 3);
        break;
      }

      if (result.status >= 400) {
        emit({
          status: result.status,
          challenged: false,
          products: [],
          error: `HTTP ${result.status} returned by '${pageUrl}'.`
        }, 4);
        break;
      }

      let parsed = parseProductsPayload(result.body, pageUrl, result.title);
      if (!parsed.ok && pageNum > 1) {
        result = await loadViaNavigation(page, pageUrl);
        if (result.challenged) {
          emit({
            status: result.status || 403,
            challenged: true,
            products: [],
            error: `Access blocked (HTTP 403) by '${pageUrl}'. The browser could not pass the Cloudflare challenge; try -Headed.`
          }, 3);
          break;
        }
        if (result.status >= 400) {
          emit({
            status: result.status,
            challenged: false,
            products: [],
            error: `HTTP ${result.status} returned by '${pageUrl}'.`
          }, 4);
          break;
        }
        parsed = parseProductsPayload(result.body, pageUrl, result.title);
      }

      if (!parsed.ok) {
        emit({ status: result.status, challenged: false, products: [], error: parsed.error }, 5);
        break;
      }

      for (const p of parsed.products) {
        if (p && typeof p.handle === 'string' && p.handle.length > 0) {
          allProducts.push({
            handle: p.handle,
            title: typeof p.title === 'string' ? p.title : '',
            spotsLeft: countSpots(p)
          });
        }
      }

      if (parsed.products.length < 250) {
        emit({ status: 200, challenged: false, products: allProducts }, 0);
        break;
      }

      if (pageNum === maxPages) {
        emit({ status: 200, challenged: false, products: allProducts }, 0);
      }
    }
  }
} catch (e) {
  emit({
    status: 0,
    challenged: false,
    browserUnavailable: false,
    products: [],
    error: String(e?.message ?? e).split('\n')[0]
  }, 1);
} finally {
  if (context) {
    await context.close().catch(() => {});
  }
}
'@

function Get-CollectionProductsViaPlaywright {
    param(
        [int]$MaximumPages = 10,
        [int]$TimeoutSeconds = 60
    )

    $nodePath = Get-NodePath
    if (-not $nodePath) {
        return $null
    }

    $playwrightEntry = Join-Path $PSScriptRoot 'node_modules' 'playwright-core' 'index.mjs'
    if (-not (Test-Path -LiteralPath $playwrightEntry)) {
        $playwrightEntry = Join-Path $PSScriptRoot 'node_modules' 'playwright-core' 'index.js'
        if (-not (Test-Path -LiteralPath $playwrightEntry)) {
            return $null
        }
    }

    $profileDir = Join-Path $PSScriptRoot '.browser-profile'
    $nodeArgs = [System.Collections.Generic.List[string]]::new()
    $nodeArgs.Add('--input-type=module')
    $nodeArgs.Add('-')
    $nodeArgs.Add($playwrightEntry)
    $nodeArgs.Add($script:ProductsJsonBaseUrl)
    $nodeArgs.Add($profileDir)
    $nodeArgs.Add([string]$MaximumPages)
    $nodeArgs.Add([string]$TimeoutSeconds)
    if ($Headed) {
        $nodeArgs.Add('--headed')
    }

    Write-Verbose "Loading collection products JSON via Node + Playwright ($($script:ProductsJsonBaseUrl))."

    $processTimeoutMs = [Math]::Min(600000, ($MaximumPages * $TimeoutSeconds + 30) * 1000)
    $procResult = Invoke-ExternalProcess `
        -FilePath $nodePath `
        -Arguments $nodeArgs.ToArray() `
        -StandardInput $script:PlaywrightPaginatorScript `
        -TimeoutMilliseconds $processTimeoutMs

    $json = $null
    if ($procResult.StdOut -and $procResult.StdOut.Trim()) {
        try {
            $json = $procResult.StdOut | ConvertFrom-Json
        }
        catch {
            $json = $null
        }
    }

    if (-not $json) {
        $errDetail = ($procResult.StdErr, $procResult.StdOut | Where-Object { $_ -and $_.Trim() }) -join ' '
        throw (New-CherryRequestException `
            -Kind 'BrowserUnavailable' `
            -Message "Browser fallback failed (exit $($procResult.ExitCode)): $($errDetail.Trim())")
    }

    $hasBrowserUnavailable = $json.PSObject.Properties['browserUnavailable'] -and $json.browserUnavailable
    if ($hasBrowserUnavailable) {
        throw (New-CherryRequestException `
            -Kind 'BrowserUnavailable' `
            -Message "Browser fallback failed: $($json.error). If the browser is missing run: npx playwright-core install chromium-headless-shell (on Linux, if it then fails to start: sudo npx playwright install-deps chromium)")
    }

    $status = if ($json.PSObject.Properties['status']) { [int]$json.status } else { 0 }
    $challenged = $json.PSObject.Properties['challenged'] -and $json.challenged
    $errorMsg = if ($json.PSObject.Properties['error'] -and $json.error) { [string]$json.error } else { '' }

    if ($challenged -or $status -eq 403) {
        $msg = if ($errorMsg) { $errorMsg } else { "Access blocked (HTTP 403) by '$($script:ProductsJsonBaseUrl)'. The browser could not pass the Cloudflare challenge; try -Headed." }
        throw (New-CherryRequestException -Kind 'Blocked' -StatusCode 403 -Message $msg)
    }

    if ($status -eq 429) {
        $msg = if ($errorMsg) { $errorMsg } else { "Rate limited (HTTP 429) by '$($script:ProductsJsonBaseUrl)'." }
        throw (New-CherryRequestException -Kind 'RateLimited' -StatusCode 429 -Message $msg)
    }

    if ($errorMsg -or $status -ge 400) {
        $msg = if ($errorMsg) { $errorMsg } else { "HTTP $status returned by '$($script:ProductsJsonBaseUrl)'." }
        throw (New-CherryRequestException -Kind 'HttpError' -StatusCode $status -Message $msg)
    }

    $products = [System.Collections.Generic.List[object]]::new()
    if ($json.PSObject.Properties['products'] -and $json.products) {
        foreach ($p in $json.products) {
            if (-not $p.handle) {
                continue
            }
            $products.Add([pscustomobject]@{
                Handle    = [string]$p.handle
                Title     = [string]$p.title
                Url       = "$($script:BaseUrl)/products/$($p.handle)"
                SpotsLeft = [int]$p.spotsLeft
            })
        }
    }

    return $products.ToArray()
}

function Get-CollectionProductsViaNativeBrowser {
    param(
        [int]$MaximumPages = 10
    )

    $browser = Get-NativeBrowserPath
    if (-not $browser) {
        throw (New-CherryRequestException `
            -Kind 'BrowserUnavailable' `
            -Message 'Browser fallback unavailable: no Edge or Chrome found.')
    }

    $profileDir = Join-Path $PSScriptRoot '.browser-profile' 'native'
    $null = New-Item -ItemType Directory -Force -Path $profileDir

    $allProducts = [System.Collections.Generic.List[object]]::new()

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $pageUrl = "$($script:ProductsJsonBaseUrl)&page=$page"
        Write-Verbose "Loading '$pageUrl' in $browser (headless)."

        if ($IsWindows) {
            # Edge/Chrome are GUI-subsystem programs on Windows; Start-Process -Wait with
            # file redirection both waits for completion and captures stdout reliably.
            $outFile = [System.IO.Path]::GetTempFileName()
            $errFile = [System.IO.Path]::GetTempFileName()
            try {
                $browserArgs = @(
                    '--headless=new',
                    '--disable-gpu',
                    '--no-first-run',
                    '--no-default-browser-check',
                    "--user-data-dir=`"$profileDir`"",
                    '--virtual-time-budget=20000',
                    '--dump-dom',
                    "`"$pageUrl`""
                )
                $proc = Start-Process -FilePath $browser -ArgumentList $browserArgs `
                    -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { 0 }
                $dom = if (Test-Path -LiteralPath $outFile) {
                    [System.IO.File]::ReadAllText($outFile, $script:Utf8NoBom)
                }
                else {
                    ''
                }
                $errText = if (Test-Path -LiteralPath $errFile) {
                    [System.IO.File]::ReadAllText($errFile, $script:Utf8NoBom)
                }
                else {
                    ''
                }
            }
            finally {
                Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $browserArgs = @(
                '--headless=new',
                '--disable-gpu',
                '--no-first-run',
                '--no-default-browser-check',
                "--user-data-dir=$profileDir",
                '--virtual-time-budget=20000',
                '--dump-dom',
                $pageUrl
            )
            $procResult = Invoke-ExternalProcess `
                -FilePath $browser `
                -Arguments $browserArgs `
                -TimeoutMilliseconds 60000
            $exitCode = $procResult.ExitCode
            $dom = if ($procResult.StdOut) { $procResult.StdOut } else { '' }
            $errText = if ($procResult.StdErr) { $procResult.StdErr } else { '' }
        }

        if (-not $dom.Trim()) {
            $errSnippet = Get-BodySnippet -Text $errText
            $errSuffix = if ($errSnippet) { " Stderr: $errSnippet" } else { '' }
            throw (New-CherryRequestException `
                -Kind 'BrowserUnavailable' `
                -Message "Browser fallback failed (exit $exitCode): $browser produced no output.$errSuffix")
        }

        if ($dom -match '<title>[^<]*(Verifying|Just a moment|Attention Required)') {
            throw (New-CherryRequestException `
                -Kind 'Blocked' `
                -StatusCode 403 `
                -Message "Access blocked (HTTP 403) by '$pageUrl'. The headless browser could not pass the Cloudflare challenge.")
        }

        # Chromium renders a JSON response inside <pre>...</pre>; unwrap it.
        $content = $dom
        if ($dom -match '(?s)<pre[^>]*>(.*?)</pre>') {
            $content = [System.Net.WebUtility]::HtmlDecode($Matches[1])
        }

        if ($content.TrimStart() -notmatch '^[\{\[]') {
            $title = if ($dom -match '(?is)<title[^>]*>(.*?)</title>') {
                ($Matches[1] -replace '\s+', ' ').Trim()
            }
            else {
                '(none)'
            }
            $plainText = ($dom -replace '(?is)<(script|style)[^>]*>.*?</\1>', ' ' -replace '<[^>]+>', ' ')
            $snippet = Get-BodySnippet -Text $plainText
            throw (New-CherryRequestException `
                -Kind 'HttpError' `
                -Message "Browser fallback failed: '$pageUrl' did not return JSON. Page title: '$title'. Text: $snippet")
        }

        $parsed = ConvertFrom-ProductsJson -JsonText $content -SourceUrl $pageUrl
        foreach ($p in $parsed.Products) {
            $allProducts.Add($p)
        }

        if ($parsed.RawCount -lt 250) {
            break
        }
    }

    return $allProducts.ToArray()
}

function Invoke-CherryCurlRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$CurlPath
    )

    $headerFile = [System.IO.Path]::GetTempFileName()
    $bodyFile = [System.IO.Path]::GetTempFileName()

    $arguments = @(
        '--location',
        '--silent',
        '--show-error',
        '--max-time', '45',
        '--user-agent', $script:Headers['User-Agent'],
        '--header', "Accept: $($script:Headers['Accept'])",
        '--dump-header', $headerFile,
        '--output', $bodyFile,
        '--write-out', '%{http_code}',
        $Uri
    )

    try {
        $procResult = Invoke-ExternalProcess `
            -FilePath $CurlPath `
            -Arguments $arguments `
            -TimeoutMilliseconds 55000

        $rawHeaders = if (Test-Path -LiteralPath $headerFile) {
            [System.IO.File]::ReadAllText($headerFile, $script:Utf8NoBom)
        }
        else {
            ''
        }
        $body = if (Test-Path -LiteralPath $bodyFile) {
            [System.IO.File]::ReadAllText($bodyFile, $script:Utf8NoBom)
        }
        else {
            ''
        }
    }
    finally {
        Remove-Item -LiteralPath $headerFile, $bodyFile -Force -ErrorAction SilentlyContinue
    }

    $httpCode = 0
    $codeText = if ($procResult.StdOut) { $procResult.StdOut.Trim() } else { '' }
    if ($codeText -match '^\d{3}$') {
        $httpCode = [int]$codeText
    }

    if ($httpCode -eq 429 -or $body -match 'local_rate_limited') {
        $diag = Get-CherryBlockDiagnostics -RawHeaders $rawHeaders -Body $body
        throw (New-CherryRequestException `
            -Kind 'RateLimited' `
            -StatusCode 429 `
            -Message "Rate limited (HTTP 429) by '$Uri'.$diag")
    }

    if ($httpCode -eq 403) {
        $diag = Get-CherryBlockDiagnostics -RawHeaders $rawHeaders -Body $body
        throw (New-CherryRequestException `
            -Kind 'Blocked' `
            -StatusCode 403 `
            -Message "Access blocked (HTTP 403) by '$Uri'.$diag")
    }

    if ($procResult.ExitCode -ne 0) {
        $stderr = if ($procResult.StdErr) { " $($procResult.StdErr.Trim())" } else { '' }
        throw (New-CherryRequestException `
            -Kind 'HttpError' `
            -StatusCode $httpCode `
            -Message "curl exited with code $($procResult.ExitCode).$stderr")
    }

    if ($httpCode -ge 400 -or $httpCode -eq 0) {
        throw (New-CherryRequestException `
            -Kind 'HttpError' `
            -StatusCode $httpCode `
            -Message "HTTP $httpCode returned by '$Uri'.")
    }

    return $body
}

function Invoke-CherryHttpRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateRange(1, 10)]
        [int]$MaximumAttempts = 2
    )

    $curlPath = Get-NativeCurlPath

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if ($curlPath) {
                return Invoke-CherryCurlRequest -Uri $Uri -CurlPath $curlPath
            }

            $response = Invoke-WebRequest `
                -Uri $Uri `
                -Headers $script:Headers `
                -MaximumRedirection 5 `
                -TimeoutSec 45
            return [string]$response.Content
        }
        catch {
            $kind = Get-ExceptionKind -Exception $_.Exception
            if ($kind -in @('RateLimited', 'Blocked')) {
                throw
            }

            if ($null -eq $kind) {
                $statusCode = 0
                $retryAfterSeconds = $null
                $responseObj = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }

                if ($_.Exception.PSObject.Properties['StatusCode'] -and $_.Exception.StatusCode) {
                    try { $statusCode = [int]$_.Exception.StatusCode } catch { }
                }
                if ($statusCode -eq 0 -and $responseObj) {
                    try { $statusCode = [int]$responseObj.StatusCode } catch { }
                }

                if ($responseObj -and $responseObj.Headers) {
                    try {
                        if ($responseObj.Headers.RetryAfter -and $responseObj.Headers.RetryAfter.Delta) {
                            $retryAfterSeconds = [int]$responseObj.Headers.RetryAfter.Delta.TotalSeconds
                        }
                    }
                    catch { }
                    try {
                        if (-not $retryAfterSeconds -and $responseObj.Headers.Contains('Retry-After')) {
                            $vals = @($responseObj.Headers.GetValues('Retry-After'))
                            if ($vals.Count -gt 0) {
                                $retryAfterSeconds = [int]$vals[0]
                            }
                        }
                    }
                    catch { }
                }

                if ($statusCode -eq 429 -or $_.Exception.Message -match '\b429\b|Too Many Requests') {
                    $wait = if ($retryAfterSeconds) { " Retry after $retryAfterSeconds seconds." } else { '' }
                    throw (New-CherryRequestException `
                        -Kind 'RateLimited' `
                        -StatusCode 429 `
                        -Message "Rate limited (HTTP 429) by '$Uri'.$wait")
                }

                if ($statusCode -eq 403 -or $_.Exception.Message -match '\b403\b|Forbidden') {
                    $rawHdr = ''
                    try {
                        if ($responseObj -and $responseObj.Headers) {
                            $rawHdr = ($responseObj.Headers | ForEach-Object { "$($_.Key): $($_.Value -join ', ')" }) -join "`n"
                        }
                    }
                    catch { }
                    $body = if ($_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
                    $diag = Get-CherryBlockDiagnostics -RawHeaders $rawHdr -Body $body
                    throw (New-CherryRequestException `
                        -Kind 'Blocked' `
                        -StatusCode 403 `
                        -Message "Access blocked (HTTP 403) by '$Uri'.$diag")
                }
            }

            if ($attempt -eq $MaximumAttempts) {
                throw
            }

            Write-Warning (
                "Request failed for '$Uri'. " +
                "Retrying in $($attempt * 2) seconds. " +
                "Error: $($_.Exception.Message)"
            )
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Get-CollectionProductsViaHttp {
    param(
        [int]$MaximumPages = 10
    )

    $allProducts = [System.Collections.Generic.List[object]]::new()

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $pageUrl = "$($script:ProductsJsonBaseUrl)&page=$page"
        Write-Verbose "Loading collection products JSON page $page`: $pageUrl"

        $content = Invoke-CherryHttpRequest -Uri $pageUrl
        $parsed = ConvertFrom-ProductsJson -JsonText $content -SourceUrl $pageUrl

        foreach ($p in $parsed.Products) {
            $allProducts.Add($p)
        }

        if ($parsed.RawCount -lt 250) {
            break
        }
    }

    return $allProducts.ToArray()
}

function Get-CollectionProducts {
    $rawProducts = $null

    if (-not $NoBrowser) {
        $playwrightUnavailableMsg = $null

        try {
            $rawProducts = Get-CollectionProductsViaPlaywright
        }
        catch {
            if ((Get-ExceptionKind -Exception $_.Exception) -eq 'BrowserUnavailable') {
                $playwrightUnavailableMsg = $_.Exception.Message
                Write-Verbose "$playwrightUnavailableMsg Trying system Edge/Chrome."
            }
            else {
                throw
            }
        }

        if ($null -eq $rawProducts) {
            try {
                $rawProducts = Get-CollectionProductsViaNativeBrowser
            }
            catch {
                if ((Get-ExceptionKind -Exception $_.Exception) -eq 'BrowserUnavailable') {
                    $reason = if ($playwrightUnavailableMsg) { $playwrightUnavailableMsg } else { $_.Exception.Message }
                    Write-Warning "$reason Falling back to curl for this run."
                    $rawProducts = $null
                }
                else {
                    throw
                }
            }
        }
    }

    if ($null -eq $rawProducts) {
        $rawProducts = Get-CollectionProductsViaHttp
    }

    $seenHandles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uniqueProducts = [System.Collections.Generic.List[object]]::new()

    foreach ($product in $rawProducts) {
        if ($product.Handle -and $seenHandles.Add($product.Handle)) {
            $uniqueProducts.Add($product)
        }
    }

    if ($uniqueProducts.Count -eq 0) {
        Write-Warning "No products found in collection JSON for '$($script:ProductsJsonBaseUrl)'."
    }

    return $uniqueProducts.ToArray()
}

#endregion

#region Date, Classification & Formatting

function Get-TargetDay {
    param(
        [string]$RequestedDay
    )

    if ($RequestedDay) {
        return $RequestedDay
    }

    return $script:SydneyNow.DayOfWeek.ToString()
}

function Get-TargetDate {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    $today = $script:SydneyNow.Date
    $targetDayOfWeek = [System.DayOfWeek]::$Day
    $daysUntilTarget = ([int]$targetDayOfWeek - [int]$today.DayOfWeek + 7) % 7

    return $today.AddDays($daysUntilTarget)
}

function Get-TextBreakDate {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $match = $script:MonthDayRegex.Match($Text)
    if (-not $match.Success) {
        $match = $script:DayMonthRegex.Match($Text)
    }
    if (-not $match.Success) {
        return $null
    }

    $monthName = $match.Groups['month'].Value.ToLowerInvariant()
    $month = $script:MonthNumbers[$monthName]
    $dayOfMonth = [int]$match.Groups['day'].Value
    $today = $script:SydneyNow.Date

    $bestDate = $null
    $bestDiff = [double]::MaxValue

    # Check -1, 0, and +1 year to handle year rollovers and leap-year Feb 29 dates cleanly.
    foreach ($candidateYear in ($today.Year - 1), $today.Year, ($today.Year + 1)) {
        try {
            $candidate = [datetime]::new($candidateYear, $month, $dayOfMonth)
        }
        catch {
            continue
        }

        $diff = [Math]::Abs(($candidate - $today).TotalDays)
        if ($diff -lt $bestDiff) {
            $bestDiff = $diff
            $bestDate = $candidate
        }
    }

    return $bestDate
}

function Get-BreakClassification {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $weeklyMatch = $script:WeeklyBreakNameRegex.Match($Title)
    if ($weeklyMatch.Success) {
        $rawName = $weeklyMatch.Groups['name'].Value.ToLowerInvariant()
        $shortName = switch -Regex ($rawName) {
            '^macho'   { 'Machos'; break }
            '^spenda'  { 'Spenda'; break }
            '^punter'  { 'Punterz'; break }
            '^slugger' { 'Sluggerz'; break }
            '^amigo'   { 'Amigos'; break }
        }

        return [pscustomobject]@{
            Category  = 'Weekly'
            ShortName = $shortName
        }
    }

    $dailyMatch = $script:DailyBreakNameRegex.Match($Title)
    if ($dailyMatch.Success) {
        $shortName = switch ($dailyMatch.Groups['name'].Value.ToLowerInvariant()) {
            'punterz'  { 'Punterz'; break }
            'teamz'    { 'Teamz'; break }
            'squadz'   { 'Squadz'; break }
            'derby'    { 'Derby'; break }
            'slapperz' { 'Slapperz'; break }
        }

        if ($dailyMatch.Groups['lil'].Success) {
            $shortName = "Lil $shortName"
        }

        return [pscustomobject]@{
            Category  = 'Daily'
            ShortName = $shortName
        }
    }

    return [pscustomobject]@{
        Category  = 'Other'
        ShortName = $null
    }
}

function Remove-DateText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $cleanText = $Text
    foreach ($rx in $script:DateRemovalRegexes) {
        $cleanText = $rx.Replace($cleanText, ' ')
    }

    return $script:MultiWhitespaceRegex.Replace($cleanText, ' ').Trim()
}

function Get-FullBreakDescription {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [AllowNull()]
        [string]$ShortName
    )

    if ($ShortName) {
        return $ShortName
    }

    $description = Remove-DateText -Text $Title
    $description = $script:DescriptionStripRegex.Replace($description, ' ')
    # A single box is the default, so only display a count for multi-box breaks.
    $description = $script:SingleBoxRegex.Replace($description, ' ')
    $description = $script:MultiBoxRegex.Replace($description, '(${count})')

    $description = $script:MiddleDotRegex.Replace($description, ' ')
    $description = $script:TrailingSeparatorRegex.Replace($description, ' ')
    $description = $script:LeadingSeparatorRegex.Replace($description, ' ')
    $description = $script:MultiWhitespaceRegex.Replace($description, ' ').Trim()

    if (-not $description) {
        return 'Break'
    }

    return $description
}

function Get-BreakSportEmoji {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    foreach ($rule in $script:SportEmojiRules) {
        if ($rule.Regex.IsMatch($Title)) {
            return $rule.Emoji
        }
    }

    return ''
}

function Get-DayCollectionLine {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    # Most weekday collections are empty, so search by the date product titles use.
    $dateText = (Get-TargetDate -Day $Day).ToString(
        'MMM d',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $query = [uri]::EscapeDataString("$dateText Opening") -replace '%20', '+'
    return "Tonights Live Openings (Plz Check Dates) -> $($script:BaseUrl)/pages/search-results?q=$query"
}

function Normalize-BreakLine {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $line = $Line.Trim()
    $line = $script:NormalizePresidentRegex.Replace($line, ' - ')
    $line = $script:NormalizeSepDotRegex.Replace($line, ' ')
    $line = $script:MiddleDotRegex.Replace($line, ' ')
    $line = $script:NormalizeBeforeSpotsRegex.Replace($line, ' ')
    $line = $script:MultiSpaceRegex.Replace($line, ' ')

    return $line.Trim()
}

function Join-BreakLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Description,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SportEmoji,

        [Parameter(Mandatory)]
        [string]$SpotsText,

        [Parameter(Mandatory)]
        [string]$BreakNumber,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$BreakTypeText,

        [Parameter(Mandatory)]
        [string]$UrlText
    )

    $line = '{0} {1} {2} {3}{4} -> {5}' -f `
        $Description,
        $SportEmoji,
        $SpotsText,
        $BreakNumber,
        $BreakTypeText,
        $UrlText

    return Normalize-BreakLine -Line $line
}

function Format-BreakLine {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Url,

        [AllowNull()]
        [Nullable[int]]$SpotsLeft,

        [Parameter(Mandatory)]
        [string]$Category,

        [AllowNull()]
        [string]$ShortName,

        [switch]$YouTube
    )

    $breakNumber = '#?'
    $numMatch = $script:BreakNumberRegex.Match($Title)
    if ($numMatch.Success) {
        $breakNumber = "#$($numMatch.Groups['number'].Value)"
    }

    $description = Get-FullBreakDescription -Title $Title -ShortName $ShortName
    $sportEmoji = Get-BreakSportEmoji -Title $Title
    $isNamedRecurringBreak = $Category -in @('Daily', 'Weekly')

    $spotsText = if ($null -eq $SpotsLeft) {
        if ($isNamedRecurringBreak) { '(? spots left)' } else { '(? spots)' }
    }
    else {
        $noun = if ($SpotsLeft -eq 1) { 'spot' } else { 'spots' }
        if ($isNamedRecurringBreak) { "($SpotsLeft $noun left)" } else { "($SpotsLeft $noun)" }
    }

    $breakTypeText = ''
    foreach ($rule in $script:AllocationRules) {
        if ($rule.Regex.IsMatch($Title)) {
            $breakTypeText = $rule.Suffix
            break
        }
    }

    $line = Join-BreakLine `
        -Description $description `
        -SportEmoji $sportEmoji `
        -SpotsText $spotsText `
        -BreakNumber $breakNumber `
        -BreakTypeText $breakTypeText `
        -UrlText $Url

    if ($YouTube -and $line.Length -gt 200) {
        $fixedLine = Join-BreakLine `
            -Description '' `
            -SportEmoji $sportEmoji `
            -SpotsText $spotsText `
            -BreakNumber $breakNumber `
            -BreakTypeText $breakTypeText `
            -UrlText $Url

        $separatorLength = if ($fixedLine) { 1 } else { 0 }
        $descriptionLength = [Math]::Max(0, 200 - $fixedLine.Length - $separatorLength)

        if ($description.Length -gt $descriptionLength) {
            $description = $description.Substring(0, $descriptionLength).Trim()
        }

        $line = Join-BreakLine `
            -Description $description `
            -SportEmoji $sportEmoji `
            -SpotsText $spotsText `
            -BreakNumber $breakNumber `
            -BreakTypeText $breakTypeText `
            -UrlText $Url
    }

    return $line
}

function ConvertTo-BreakResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Product,

        [Parameter(Mandatory)]
        [pscustomobject]$Classification,

        [switch]$YouTube
    )

    $line = Format-BreakLine `
        -Title $Product.Title `
        -Url $Product.Url `
        -SpotsLeft $Product.SpotsLeft `
        -Category $Classification.Category `
        -ShortName $Classification.ShortName `
        -YouTube:$YouTube

    return [pscustomobject]@{
        Title     = $Product.Title
        Url       = $Product.Url
        SpotsLeft = $Product.SpotsLeft
        Category  = $Classification.Category
        ShortName = $Classification.ShortName
        IsOpen    = ($null -ne $Product.SpotsLeft -and $Product.SpotsLeft -gt 0)
        Line      = $line
    }
}

function Get-SelectedRecurringBreaks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [switch]$IncludeDailies,

        [switch]$IncludeWeeklies
    )

    $selected = [System.Collections.Generic.List[object]]::new()

    if ($IncludeDailies) {
        foreach ($item in $Results) {
            if ($item.IsOpen -and $item.Category -eq 'Daily') {
                $selected.Add($item)
            }
        }
    }

    if ($IncludeWeeklies) {
        foreach ($item in $Results) {
            if ($item.IsOpen -and $item.Category -eq 'Weekly') {
                $selected.Add($item)
            }
        }
    }

    return $selected.ToArray()
}

#endregion

#region Console & Text Output Rendering

function Get-ResultSections {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $dailies = [System.Collections.Generic.List[object]]::new()
    $weeklies = [System.Collections.Generic.List[object]]::new()
    $other = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $Results) {
        switch ($item.Category) {
            'Daily'  { $dailies.Add($item); break }
            'Weekly' { $weeklies.Add($item); break }
            default  { $other.Add($item); break }
        }
    }

    $sections = [System.Collections.Generic.List[object]]::new()
    if ($dailies.Count -gt 0) {
        $sections.Add([pscustomobject]@{ Title = 'Dailies'; Items = $dailies.ToArray() })
    }
    if ($weeklies.Count -gt 0) {
        $sections.Add([pscustomobject]@{ Title = 'Weeklies'; Items = $weeklies.ToArray() })
    }
    if ($other.Count -gt 0) {
        $sections.Add([pscustomobject]@{ Title = 'Other Breaks'; Items = $other.ToArray() })
    }

    return $sections.ToArray()
}

function Write-BreakResultLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    $statusColour = if ($null -eq $Item.SpotsLeft) {
        'Gray'
    }
    elseif ($Item.SpotsLeft -le 0) {
        'DarkGray'
    }
    elseif ($Item.SpotsLeft -le 3) {
        'Red'
    }
    elseif ($Item.SpotsLeft -le 10) {
        'Yellow'
    }
    else {
        'Green'
    }

    Write-Host $Item.Line -ForegroundColor $statusColour
}

function Show-BreakResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Day,

        [switch]$IncludeDayCollectionLink
    )

    $targetDate = Get-TargetDate -Day $Day

    Write-Host ''
    Write-Host (
        'Cherry break check - {0}, {1} (checked {2})' -f
        $Day,
        $targetDate.ToString('dd MMM yyyy'),
        $script:SydneyNow.ToString('dd MMM yyyy HH:mm')
    ) -ForegroundColor Cyan

    if ($IncludeDayCollectionLink) {
        Write-Host (Get-DayCollectionLine -Day $Day) -ForegroundColor Cyan
    }

    Write-Host ''

    if (-not $Results) {
        Write-Host 'No matching breaks were found.' -ForegroundColor Yellow
        return
    }

    $sections = @(Get-ResultSections -Results $Results)
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $section = $sections[$i]
        Write-Host $section.Title -ForegroundColor Cyan

        foreach ($item in $section.Items) {
            Write-BreakResultLine -Item $item
        }

        if ($i -lt ($sections.Count - 1)) {
            Write-Host ''
        }
    }
}

function Save-TextResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Day,

        [switch]$IncludeDayCollectionLink
    )

    if (-not $OutputPath) {
        return
    }

    $resolvedPath = Resolve-ScriptRelativePath -Path $OutputPath
    $targetDate = Get-TargetDate -Day $Day
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add(
        ('Cherry break check - {0}, {1}' -f
            $Day,
            $targetDate.ToString('dd MMM yyyy'))
    )

    if ($IncludeDayCollectionLink) {
        $lines.Add((Get-DayCollectionLine -Day $Day))
    }

    if (-not $Results) {
        $lines.Add('No matching breaks were found.')
    }
    else {
        $sections = @(Get-ResultSections -Results $Results)
        for ($i = 0; $i -lt $sections.Count; $i++) {
            $section = $sections[$i]
            $lines.Add($section.Title)

            foreach ($item in $section.Items) {
                $lines.Add($item.Line)
            }

            if ($i -lt ($sections.Count - 1)) {
                $lines.Add('')
            }
        }
    }

    $directory = Split-Path -Parent $resolvedPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $lines | Set-Content -LiteralPath $resolvedPath -Encoding utf8

    Write-Host (
        "TXT FILE UPDATED SUCCESSFULLY: $resolvedPath ($($Results.Count) result(s), overwritten)"
    ) -ForegroundColor Green
}

#endregion

#region Twitch IRC Client

function Get-RedactedTwitchIrcLine {
    param(
        [AllowNull()]
        [string]$Line
    )

    if ($null -eq $Line) {
        return $null
    }

    if ($Line -match '^PASS\s+') {
        return 'PASS [redacted]'
    }

    return $Line
}

function Read-TwitchIrcLines {
    param(
        [Parameter(Mandatory)]
        [System.IO.StreamReader]$Reader,

        [System.IO.StreamWriter]$Writer,

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 1000,

        [scriptblock]$StopWhen
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $remainingMilliseconds = [int][Math]::Max(
            50,
            ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        )

        try {
            $Reader.BaseStream.ReadTimeout = $remainingMilliseconds
            $line = $Reader.ReadLine()

            if ($null -eq $line) {
                break
            }

            if ($Writer -and $line -match '^PING\s+(?<payload>.+)$') {
                $pong = "PONG $($Matches['payload'])"
                Write-Verbose "Twitch IRC -> $pong"
                $Writer.WriteLine($pong)
                continue
            }

            $lines.Add($line)
            Write-Verbose "Twitch IRC <- $(Get-RedactedTwitchIrcLine -Line $line)"

            if ($StopWhen -and (& $StopWhen $lines.ToArray())) {
                break
            }
        }
        catch [System.IO.IOException] {
            break
        }
    }

    return $lines.ToArray()
}

function Test-TwitchIrcLoginAccepted {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    foreach ($line in $Lines) {
        if ($line -match '(^| )001 ' -or $line -match '^:tmi\.twitch\.tv 001 ') {
            return $true
        }
    }
    return $false
}

function Get-TwitchIrcFailureLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    foreach ($line in $Lines) {
        if ($line -match 'Login authentication failed' -or
            $line -match 'Improperly formatted auth' -or
            $line -match 'Error logging in' -or
            $line -match '^:tmi\.twitch\.tv NOTICE \* :') {
            return $line
        }
    }
    return $null
}

function Test-TwitchIrcJoinAccepted {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Channel
    )

    $escapedChannel = [regex]::Escape($Channel)
    foreach ($line in $Lines) {
        if ($line -match " JOIN #$escapedChannel$" -or
            $line -match " ROOMSTATE #$escapedChannel$" -or
            $line -match " 353 .* #$escapedChannel :") {
            return $true
        }
    }
    return $false
}

function Send-TwitchChatMessages {
    param(
        [Parameter(Mandatory)]
        [string]$Channel,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter(Mandatory)]
        [string]$OAuthToken,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Messages,

        [ValidateRange(1, 30)]
        [int]$DelaySeconds = 3
    )

    if (-not $Messages) {
        Write-Host 'No Twitch messages to send.' -ForegroundColor Yellow
        return
    }

    $cleanChannel = $Channel.Trim().TrimStart('#').ToLowerInvariant()
    $cleanUser = $User.Trim().ToLowerInvariant()
    $cleanToken = $OAuthToken.Trim()

    if (-not $cleanToken.StartsWith('oauth:', [StringComparison]::OrdinalIgnoreCase)) {
        $cleanToken = "oauth:$cleanToken"
    }

    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    $sslStream = $null
    $reader = $null
    $writer = $null

    try {
        Write-Host "Connecting to Twitch IRC as $cleanUser for #$cleanChannel..." -ForegroundColor Cyan

        $connectTask = $tcpClient.ConnectAsync('irc.chat.twitch.tv', 6697)
        if (-not $connectTask.Wait(10000)) {
            throw 'Timed out connecting to Twitch IRC (irc.chat.twitch.tv:6697).'
        }
        $connectTask.GetAwaiter().GetResult()

        $sslStream = [System.Net.Security.SslStream]::new($tcpClient.GetStream(), $false)
        $sslStream.AuthenticateAsClient('irc.chat.twitch.tv')

        $reader = [System.IO.StreamReader]::new($sslStream, $script:Utf8NoBom)
        $writer = [System.IO.StreamWriter]::new($sslStream, $script:Utf8NoBom)
        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true

        Write-Verbose 'Twitch IRC -> CAP REQ :twitch.tv/commands twitch.tv/membership'
        $writer.WriteLine('CAP REQ :twitch.tv/commands twitch.tv/membership')
        Write-Verbose 'Twitch IRC -> PASS [redacted]'
        $writer.WriteLine("PASS $cleanToken")
        Write-Verbose "Twitch IRC -> NICK $cleanUser"
        $writer.WriteLine("NICK $cleanUser")

        $loginLines = Read-TwitchIrcLines `
            -Reader $reader `
            -Writer $writer `
            -TimeoutMilliseconds 5000 `
            -StopWhen {
                param($current)
                (Test-TwitchIrcLoginAccepted -Lines $current) -or
                ($null -ne (Get-TwitchIrcFailureLine -Lines $current))
            }

        $failureLine = Get-TwitchIrcFailureLine -Lines $loginLines
        if ($failureLine) {
            throw "Twitch IRC login failed: $(Get-RedactedTwitchIrcLine -Line $failureLine)"
        }

        if (Test-TwitchIrcLoginAccepted -Lines $loginLines) {
            Write-Host 'Twitch IRC login accepted.' -ForegroundColor Green
        }
        else {
            Write-Warning (
                'Twitch IRC did not send a login confirmation before the timeout. ' +
                'Messages will still be attempted; rerun with -Verbose to inspect server lines.'
            )
        }

        Write-Verbose "Twitch IRC -> JOIN #$cleanChannel"
        $writer.WriteLine("JOIN #$cleanChannel")

        $joinLines = Read-TwitchIrcLines `
            -Reader $reader `
            -Writer $writer `
            -TimeoutMilliseconds 5000 `
            -StopWhen {
                param($current)
                (Test-TwitchIrcJoinAccepted -Lines $current -Channel $cleanChannel) -or
                ($null -ne (Get-TwitchIrcFailureLine -Lines $current))
            }

        $joinFailureLine = Get-TwitchIrcFailureLine -Lines $joinLines
        if ($joinFailureLine) {
            throw "Twitch IRC join failed: $(Get-RedactedTwitchIrcLine -Line $joinFailureLine)"
        }

        if (Test-TwitchIrcJoinAccepted -Lines $joinLines -Channel $cleanChannel) {
            Write-Host "Twitch IRC joined #$cleanChannel." -ForegroundColor Green
        }
        else {
            Write-Warning (
                "Twitch IRC did not confirm joining #$cleanChannel before the timeout. " +
                'Messages will still be attempted; rerun with -Verbose to inspect server lines.'
            )
        }

        $delayMs = $DelaySeconds * 1000
        $noticeTimeoutMs = [Math]::Min(1000, $delayMs)
        $timer = [System.Diagnostics.Stopwatch]::new()

        for ($i = 0; $i -lt $Messages.Count; $i++) {
            $message = $Messages[$i]
            $timer.Restart()

            Write-Verbose "Twitch IRC -> PRIVMSG #$cleanChannel :$message"
            $writer.WriteLine("PRIVMSG #$cleanChannel :$message")

            $messageResponseLines = Read-TwitchIrcLines `
                -Reader $reader `
                -Writer $writer `
                -TimeoutMilliseconds $noticeTimeoutMs `
                -StopWhen {
                    param($current)
                    foreach ($l in $current) {
                        if ($l -match ' NOTICE ') { return $true }
                    }
                    return $false
                }

            $noticeLines = @($messageResponseLines | Where-Object { $_ -match ' NOTICE ' })
            if ($noticeLines.Count -gt 0) {
                foreach ($noticeLine in $noticeLines) {
                    Write-Warning "Twitch IRC notice after message: $(Get-RedactedTwitchIrcLine -Line $noticeLine)"
                }
            }
            else {
                Write-Host "Submitted Twitch chat message: $message" -ForegroundColor Green
            }

            if ($i -lt ($Messages.Count - 1)) {
                $remainingMs = $delayMs - [int]$timer.ElapsedMilliseconds
                if ($remainingMs -gt 0) {
                    Start-Sleep -Milliseconds $remainingMs
                }
            }
        }
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $sslStream) { $sslStream.Dispose() }
        $tcpClient.Dispose()
    }
}

function Publish-TwitchResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    if (-not $Twitch) {
        return
    }

    $missingSettings = [System.Collections.Generic.List[string]]::new()
    if (-not $TwitchChannel) { $missingSettings.Add('TWITCH_CHANNEL') }
    if (-not $TwitchUser) { $missingSettings.Add('TWITCH_USER') }
    if (-not $TwitchOAuthToken) { $missingSettings.Add('TWITCH_OAUTH_TOKEN') }

    if ($missingSettings.Count -gt 0) {
        throw (
            'Twitch sending was requested, but these setting(s) are missing: ' +
            ($missingSettings -join ', ')
        )
    }

    $includeDailies = $Dailies -or -not $Weeklies
    $selected = @(
        Get-SelectedRecurringBreaks `
            -Results $Results `
            -IncludeDailies:$includeDailies `
            -IncludeWeeklies:$Weeklies
    )
    $messages = @($selected | ForEach-Object { $_.Line })

    Send-TwitchChatMessages `
        -Channel $TwitchChannel `
        -User $TwitchUser `
        -OAuthToken $TwitchOAuthToken `
        -Messages $messages `
        -DelaySeconds $TwitchMessageDelaySeconds
}

#endregion

#region Main Entrypoint

function Invoke-BreakCheck {
    $targetDay = Get-TargetDay -RequestedDay $Day
    $targetDate = Get-TargetDate -Day $targetDay

    $results = [System.Collections.Generic.List[object]]::new()
    $checkAborted = $false

    Write-Host ''
    Write-Host 'Checking all breaks...' -ForegroundColor Cyan

    try {
        $products = @(Get-CollectionProducts)
        $matchedCount = 0

        foreach ($product in $products) {
            $classification = Get-BreakClassification -Title $product.Title
            $isWeeklySearchMatch = $Weeklies -and ($classification.Category -eq 'Weekly')

            if (-not $isWeeklySearchMatch) {
                $titleDate = Get-TextBreakDate -Text $product.Title
                if ($titleDate) {
                    if ($titleDate -ne $targetDate.Date) {
                        Write-Verbose (
                            "Skipping '$($product.Title)' because its title date " +
                            "$($titleDate.ToString('dd MMM yyyy')) does not match " +
                            "$($targetDate.ToString('dd MMM yyyy'))."
                        )
                        continue
                    }
                }
                else {
                    $handleDate = Get-TextBreakDate -Text $product.Handle
                    if (-not $handleDate -or $handleDate -ne $targetDate.Date) {
                        if ($handleDate) {
                            Write-Verbose (
                                "Skipping '$($product.Title)' because its URL date " +
                                "$($handleDate.ToString('dd MMM yyyy')) does not match " +
                                "$($targetDate.ToString('dd MMM yyyy'))."
                            )
                        }
                        continue
                    }
                }
            }

            $matchedCount++
            $results.Add((ConvertTo-BreakResult `
                -Product $product `
                -Classification $classification `
                -YouTube:$YouTube))
        }

        Write-Host "Found $matchedCount matching product(s) out of $($products.Count) total."
    }
    catch {
        $checkAborted = $true
        $msg = $_.Exception.Message
        $kind = Get-ExceptionKind -Exception $_.Exception

        if ($kind -eq 'RateLimited' -or $msg -match '\b429\b') {
            Write-Host ''
            Write-Host "Rate limit reached (HTTP 429): $msg" -ForegroundColor Red
            Write-Host 'Shopify storefront edge is rate limiting requests from this IP.' -ForegroundColor Yellow
            Write-Host 'Please wait a few minutes before trying again to allow the rate limit window to reset.' -ForegroundColor Yellow
            Write-Host ''
        }
        elseif ($kind -eq 'Blocked' -or $msg -match '\b403\b') {
            Write-Host ''
            Write-Host "Access blocked (HTTP 403): $msg" -ForegroundColor Red
            Write-Host 'Cloudflare / Shopify bot protection blocked automated requests to the collection.' -ForegroundColor Yellow
            Write-Host ''
        }
        else {
            Write-Warning "Could not check breaks collection: $msg"
        }
    }

    if ($checkAborted) {
        return @()
    }

    $allResults = @(
        $results |
            Sort-Object `
                @{ Expression = { $null -eq $_.SpotsLeft } },
                SpotsLeft,
                Title
    )

    if ($Dailies -or $Weeklies) {
        $allResults = @(
            Get-SelectedRecurringBreaks `
                -Results $allResults `
                -IncludeDailies:$Dailies `
                -IncludeWeeklies:$Weeklies
        )
    }

    Show-BreakResults `
        -Results $allResults `
        -Day $targetDay `
        -IncludeDayCollectionLink:$DayWasExplicitlyRequested

    Save-TextResults `
        -Results $allResults `
        -Day $targetDay `
        -IncludeDayCollectionLink:$DayWasExplicitlyRequested

    Publish-TwitchResults -Results $allResults

    return $allResults
}

try {
    $null = Invoke-BreakCheck
}
catch {
    Write-Error "Break check failed: $($_.Exception.Message)"
}

#endregion
