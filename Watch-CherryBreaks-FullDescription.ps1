#requires -Version 5.1

<#
Checks Cherry Collectables group breaks and prints full-description
lines in this format:

SPOTS LEFT | BREAK NUMBER | DESCRIPTION | URL

By default, the script checks today's Sydney day. Use -Day to check the
next matching weekday instead.

Examples:

.\Watch-CherryBreaks-PowerShell51.ps1
.\Watch-CherryBreaks-PowerShell51.ps1 -Day Friday
.\Watch-CherryBreaks-PowerShell51.ps1 -Day Friday -OutputPath cherry-break-results.txt
.\Watch-CherryBreaks-PowerShell51.ps1 -Day Friday -YouTube
.\Watch-CherryBreaks-PowerShell51.ps1 -Day Friday -Dailies -Twitch
.\Watch-CherryBreaks-PowerShell51.ps1 -Day Friday -Dailies -Weeklies -Twitch

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

    [string]$EnvPath = '.env'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DayWasExplicitlyRequested = $PSBoundParameters.ContainsKey('Day')

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

$BaseUrl = 'https://www.cherrycollectables.com.au'
$CollectionPath = '/collections/nba-group-breaks'

$Headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36'
    'Accept'     = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
}

$ProductJsonCache = @{}

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
        $first = $trimmed.Substring(0, 1)
        $last = $trimmed.Substring($trimmed.Length - 1, 1)

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

        $name = $match.Groups['name'].Value
        $value = ConvertFrom-DotEnvValue -Value $match.Groups['value'].Value
        $values[$name] = $value
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
$TwitchChannel = Get-ConfigValue `
    -CurrentValue $TwitchChannel `
    -DotEnvValues $DotEnvValues `
    -Names @('TWITCH_CHANNEL')
$TwitchUser = Get-ConfigValue `
    -CurrentValue $TwitchUser `
    -DotEnvValues $DotEnvValues `
    -Names @('TWITCH_USER', 'TWITCH_BOT_USER')
$TwitchOAuthToken = Get-ConfigValue `
    -CurrentValue $TwitchOAuthToken `
    -DotEnvValues $DotEnvValues `
    -Names @('TWITCH_OAUTH_TOKEN')

function Get-SydneyDate {
    $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById(
        'AUS Eastern Standard Time'
    )

    return [TimeZoneInfo]::ConvertTimeFromUtc(
        [datetime]::UtcNow,
        $timeZone
    )
}

function Get-TargetDay {
    param(
        [string]$RequestedDay
    )

    if ($RequestedDay) {
        return $RequestedDay
    }

    return (Get-SydneyDate).DayOfWeek.ToString()
}

function Get-TargetDate {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    $today = (Get-SydneyDate).Date
    $targetDayOfWeek = [System.DayOfWeek]::$Day
    $daysUntilTarget = ([int]$targetDayOfWeek - [int]$today.DayOfWeek + 7) % 7

    return $today.AddDays($daysUntilTarget)
}

function Get-UnfilteredCollectionUrl {
    return "$BaseUrl${CollectionPath}?sort=creation_date"
}

function Get-CollectionUrl {
    param(
        [string]$Day
    )

    $url = Get-UnfilteredCollectionUrl

    if ($Day) {
        $filterValue = "Day,Day_$Day"
        $encodedFilter = [uri]::EscapeDataString($filterValue)
        $url += "&filters=$encodedFilter"
    }

    return $url
}

function Get-TextBreakDate {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $monthNumbers = @{
        jan  = 1
        feb  = 2
        mar  = 3
        apr  = 4
        may  = 5
        jun  = 6
        jul  = 7
        aug  = 8
        sep  = 9
        sept = 9
        oct  = 10
        nov  = 11
        dec  = 12
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?:^|[-_/\s(])(?<month>jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[-_/\s]+(?<day>\d{1,2})(?:[-_/\s)]|$)'
    )

    if (-not $match.Success) {
        return $null
    }

    $monthName = $match.Groups['month'].Value.ToLowerInvariant()
    $month = $monthNumbers[$monthName]
    $dayOfMonth = [int]$match.Groups['day'].Value
    $sydneyDate = Get-SydneyDate
    $year = $sydneyDate.Year

    try {
        $productDate = New-Object `
            -TypeName System.DateTime `
            -ArgumentList $year, $month, $dayOfMonth
    }
    catch {
        return $null
    }

    if ($productDate -lt $sydneyDate.Date.AddMonths(-6)) {
        $productDate = $productDate.AddYears(1)
    }
    elseif ($productDate -gt $sydneyDate.Date.AddMonths(6)) {
        $productDate = $productDate.AddYears(-1)
    }

    return $productDate.Date
}

function Get-TextDateDay {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $productDate = Get-TextBreakDate -Text $Text

    if (-not $productDate) {
        return $null
    }

    return $productDate.DayOfWeek.ToString()
}

function Test-ProductUrlMatchesDay {
    param(
        [Parameter(Mandatory)]
        [string]$ProductUrl,

        [Parameter(Mandatory)]
        [string]$Day
    )

    $uri = [uri]$ProductUrl
    $dateDay = Get-TextDateDay -Text $uri.AbsolutePath

    return $dateDay -eq $Day
}

function Test-ProductMatchesDayFallback {
    param(
        [Parameter(Mandatory)]
        [string]$ProductUrl,

        [Parameter(Mandatory)]
        [string]$Day,

        [Parameter(Mandatory)]
        [datetime]$TargetDate
    )

    $product = Get-ProductJson -ProductUrl $ProductUrl

    if ($product) {
        $titleDate = Get-TextBreakDate -Text $product.title

        if ($titleDate) {
            return $titleDate -eq $TargetDate.Date
        }
    }

    $uri = [uri]$ProductUrl
    $urlDate = Get-TextBreakDate -Text $uri.AbsolutePath

    if ($urlDate) {
        return $urlDate -eq $TargetDate.Date
    }

    return Test-ProductUrlMatchesDay -ProductUrl $ProductUrl -Day $Day
}

function Invoke-CherryRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateRange(1, 10)]
        [int]$MaximumAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-WebRequest `
                -Uri $Uri `
                -Headers $Headers `
                -MaximumRedirection 5 `
                -TimeoutSec 45 `
                -UseBasicParsing
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                Write-Verbose (
                    "PowerShell request failed for '$Uri'. " +
                    "Trying native curl fallback. " +
                    "Error: $($_.Exception.Message)"
                )

                try {
                    return Invoke-CherryCurlRequest -Uri $Uri
                }
                catch {
                    throw
                }
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

function Get-CollectionProductsJsonUrl {
    param(
        [Parameter(Mandatory)]
        [string]$CollectionUrl
    )

    $uri = [uri]$CollectionUrl
    $path = $uri.AbsolutePath.TrimEnd('/')

    if ($path -notmatch '^/collections/[^/]+$') {
        return $null
    }

    return "$BaseUrl$path/products.json?limit=250"
}

function Get-NativeCurlCommand {
    $commands = @(
        Get-Command curl.exe -ErrorAction SilentlyContinue
        Get-Command curl -ErrorAction SilentlyContinue
    )

    return @(
        $commands |
            Where-Object { $_.CommandType -eq 'Application' }
    ) | Select-Object -First 1
}

function Invoke-CherryCurlRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $curlCommand = Get-NativeCurlCommand

    if (-not $curlCommand) {
        throw 'Native curl was not found.'
    }

    $arguments = @(
        '--location',
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        '45',
        '--user-agent',
        $Headers['User-Agent'],
        $Uri
    )

    $content = & $curlCommand.Source @arguments

    if ($LASTEXITCODE -ne 0) {
        throw "curl exited with code $LASTEXITCODE."
    }

    return [pscustomobject]@{
        Content    = ($content -join [Environment]::NewLine)
        StatusCode = $null
    }
}

function ConvertTo-AbsoluteProductUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Href
    )

    if ($Href.StartsWith('//')) {
        return "https:$Href"
    }

    if ($Href.StartsWith('/')) {
        return "$BaseUrl$Href"
    }

    if ($Href -match '^https?://') {
        return $Href
    }

    return "$BaseUrl/$Href"
}

function Get-CanonicalProductUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    $uri = [uri]$Url

    # The product URL itself is enough to identify the break.
    # Preserve variant= when it exists.
    $variant = $null

    if ($uri.Query -match '(?:^\?|&)variant=(\d+)') {
        $variant = $Matches[1]
    }

    $canonical = '{0}://{1}{2}' -f `
        $uri.Scheme,
        $uri.Host,
        $uri.AbsolutePath.TrimEnd('/')

    if ($variant) {
        $canonical += "?variant=$variant"
    }

    return $canonical
}

function Get-ProductJsonUrl {
    param(
        [Parameter(Mandatory)]
        [string]$ProductUrl
    )

    $uri = [uri]$ProductUrl

    if ($uri.AbsolutePath -notmatch '/products/(?<handle>[^/?#]+)') {
        return $null
    }

    return "$BaseUrl/products/$($Matches['handle']).js"
}

function Get-ProductJson {
    param(
        [Parameter(Mandatory)]
        [string]$ProductUrl
    )

    if ($ProductJsonCache.ContainsKey($ProductUrl)) {
        return $ProductJsonCache[$ProductUrl]
    }

    $productJsonUrl = Get-ProductJsonUrl -ProductUrl $ProductUrl

    if (-not $productJsonUrl) {
        $ProductJsonCache[$ProductUrl] = $null
        return $null
    }

    try {
        Write-Verbose "Loading product JSON: $productJsonUrl"
        $jsonResponse = Invoke-CherryRequest `
            -Uri $productJsonUrl `
            -MaximumAttempts 1
        $product = $jsonResponse.Content | ConvertFrom-Json
        $ProductJsonCache[$ProductUrl] = $product

        return $product
    }
    catch {
        Write-Verbose (
            "Could not load product JSON for '$ProductUrl': " +
            $_.Exception.Message
        )

        $ProductJsonCache[$ProductUrl] = $null
        return $null
    }
}

function Get-SpotsLeftFromProductJson {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Product
    )

    $availableVariants = @(
        $Product.variants |
            Where-Object { $_.available }
    )

    if (-not $availableVariants) {
        return [pscustomobject]@{
            SpotsLeft = 0
            Status    = 'Sold out'
            Found     = $true
        }
    }

    $spots = 0
    $hasInventoryQuantities = $false

    foreach ($variant in $availableVariants) {
        if ($null -ne $variant.inventory_quantity) {
            $hasInventoryQuantities = $true
            $spots += [int]$variant.inventory_quantity
        }
    }

    if (-not $hasInventoryQuantities) {
        $spots = $availableVariants.Count
    }

    $noun = if ($spots -eq 1) { 'spot' } else { 'spots' }

    return [pscustomobject]@{
        SpotsLeft = $spots
        Status    = "$spots $noun left"
        Found     = $true
    }
}

function Get-QueryParameter {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $query = ([uri]$Url).Query

    if ($query -match "(?:^\?|&)$([regex]::Escape($Name))=([^&]+)") {
        return $Matches[1]
    }

    return $null
}

function Add-QueryParameter {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $separator = if ($Url.Contains('?')) { '&' } else { '?' }

    return "$Url$separator$Name=$Value"
}

function Set-QueryParameter {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $parts = $Url -split '\?', 2

    if ($parts.Count -eq 1) {
        return Add-QueryParameter -Url $Url -Name $Name -Value $Value
    }

    $escapedName = [regex]::Escape($Name)
    $parameters = @(
        $parts[1] -split '&' |
            Where-Object {
                $_ -and $_ -notmatch "^$escapedName="
            }
    )

    $parameters += "$Name=$Value"

    return "$($parts[0])?$($parameters -join '&')"
}

function Get-FastSimonGridUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Html,

        [Parameter(Mandatory)]
        [string]$CollectionUrl
    )

    $match = [regex]::Match(
        $Html,
        '<link[^>]+rel=["'']preload["''][^>]+href=["''](?<href>https?://ssr-grid\.fastsimon\.com[^"'']+)["'']',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        return $null
    }

    $gridUrl = [System.Net.WebUtility]::HtmlDecode(
        $match.Groups['href'].Value
    )

    $sort = Get-QueryParameter -Url $CollectionUrl -Name 'sort'
    $filters = Get-QueryParameter -Url $CollectionUrl -Name 'filters'

    if ($sort) {
        $gridUrl = Add-QueryParameter `
            -Url $gridUrl `
            -Name 'sort' `
            -Value $sort
    }

    if ($filters) {
        $gridUrl = Add-QueryParameter `
            -Url $gridUrl `
            -Name 'filters' `
            -Value $filters
    }

    return $gridUrl
}

function Add-ProductUrl {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ProductUrls,

        [Parameter(Mandatory)]
        [string]$Href
    )

    $href = $Href `
        -replace '\\u0026', '&' `
        -replace '\\/', '/'

    if ($href -notmatch '/products/') {
        return $false
    }

    $absoluteUrl = ConvertTo-AbsoluteProductUrl -Href $href
    $canonicalUrl = Get-CanonicalProductUrl -Url $absoluteUrl

    return $ProductUrls.Add($canonicalUrl)
}

function Add-ProductLinksFromCollectionJson {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ProductUrls,

        [Parameter(Mandatory)]
        [string]$CollectionUrl
    )

    $productsJsonUrl = Get-CollectionProductsJsonUrl `
        -CollectionUrl $CollectionUrl

    if (-not $productsJsonUrl) {
        return 0
    }

    $addedCount = 0
    $maximumPages = 10

    for ($page = 1; $page -le $maximumPages; $page++) {
        $pageUrl = Set-QueryParameter `
            -Url $productsJsonUrl `
            -Name 'page' `
            -Value $page

        Write-Verbose "Loading collection products JSON page $page`: $pageUrl"

        $response = Invoke-CherryRequest `
            -Uri $pageUrl `
            -MaximumAttempts 1
        $json = $response.Content | ConvertFrom-Json
        $products = @($json.products)

        foreach ($product in $products) {
            if (-not $product.handle) {
                continue
            }

            $productUrl = "$BaseUrl/products/$($product.handle)"

            if (Add-ProductUrl `
                    -ProductUrls $ProductUrls `
                    -Href $productUrl) {
                $addedCount++
            }
        }

        if ($products.Count -lt 250) {
            break
        }
    }

    return $addedCount
}

function Get-ProductLinks {
    param(
        [Parameter(Mandatory)]
        [string]$CollectionUrl
    )

    Write-Verbose "Loading collection page: $CollectionUrl"

    $productUrls = New-Object `
        -TypeName 'System.Collections.Generic.HashSet[string]' `
        -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $response = Invoke-CherryRequest `
            -Uri $CollectionUrl `
            -MaximumAttempts 1
        $html = $response.Content
    }
    catch {
        Write-Warning (
            "Collection HTML request failed for '$CollectionUrl'. " +
            "Trying Shopify products JSON fallback. " +
            "Error: $($_.Exception.Message)"
        )

        [void](Add-ProductLinksFromCollectionJson `
            -ProductUrls $productUrls `
            -CollectionUrl $CollectionUrl)

        return @($productUrls | Sort-Object)
    }

    $fastSimonGridUrl = Get-FastSimonGridUrl `
        -Html $html `
        -CollectionUrl $CollectionUrl

    # Match rendered product-card links. The base collection HTML can contain
    # unrelated fallback/product JSON, so prefer the Fast Simon grid HTML above.
    $patterns = @(
        'href\s*=\s*["''](?<href>[^"'']*/products/[^"'']+)["'']'
    )

    $addProductUrls = {
        param(
            [Parameter(Mandatory)]
            [string]$SourceHtml
        )

        $addedCount = 0

        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches(
                $SourceHtml,
                $pattern,
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )) {
                if (Add-ProductUrl `
                        -ProductUrls $productUrls `
                        -Href $match.Groups['href'].Value) {
                    $addedCount++
                }
            }
        }

        return $addedCount
    }

    if ($fastSimonGridUrl) {
        $maximumGridPages = 10

        for ($page = 1; $page -le $maximumGridPages; $page++) {
            $pageUrl = Set-QueryParameter `
                -Url $fastSimonGridUrl `
                -Name 'page' `
                -Value $page

            Write-Verbose "Loading Fast Simon grid page $page`: $pageUrl"

            $pageHtml = (Invoke-CherryRequest -Uri $pageUrl).Content
            $addedCount = & $addProductUrls -SourceHtml $pageHtml

            Write-Verbose "Found $addedCount new product link(s) on grid page $page."

            if ($addedCount -eq 0) {
                break
            }
        }
    }
    else {
        [void](& $addProductUrls -SourceHtml $html)
    }

    return @($productUrls | Sort-Object)
}

function ConvertFrom-HtmlText {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if (-not $Text) {
        return ''
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Text)

    $decoded = $decoded `
        -replace '<script\b[^>]*>.*?</script>', ' ' `
        -replace '<style\b[^>]*>.*?</style>', ' ' `
        -replace '<[^>]+>', ' ' `
        -replace '\s+', ' '

    return $decoded.Trim()
}

function Get-ProductTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $titlePatterns = @(
        '<h1[^>]*>(?<title>.*?)</h1>',
        '<meta[^>]+property=["'']og:title["''][^>]+content=["''](?<title>.*?)["'']',
        '<meta[^>]+content=["''](?<title>.*?)["''][^>]+property=["'']og:title["'']',
        '<title[^>]*>(?<title>.*?)</title>'
    )

    foreach ($pattern in $titlePatterns) {
        $match = [regex]::Match(
            $Html,
            $pattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [Text.RegularExpressions.RegexOptions]::Singleline
        )

        if ($match.Success) {
            $title = ConvertFrom-HtmlText `
                -Text $match.Groups['title'].Value

            $title = $title `
                -replace ("\s*[$([char]0x2013)|-]\s*Cherry Collectables.*$"), ''

            if ($title) {
                return $title.Trim()
            }
        }
    }

    return 'Unknown break'
}

function Get-SpotsLeft {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $text = ConvertFrom-HtmlText -Text $Html

    $soldOutPatterns = @(
        '\bsold\s*out\b',
        '\bno\s+spots?\s+left\b',
        '\bfully\s+allocated\b'
    )

    foreach ($pattern in $soldOutPatterns) {
        if ($text -match $pattern) {
            return [pscustomobject]@{
                SpotsLeft = 0
                Status    = 'Sold out'
                Found     = $true
            }
        }
    }

    $spotPatterns = @(
        '\bonly\s+(?<spots>\d+)\s+spots?\s+left\b',
        '\b(?<spots>\d+)\s+spots?\s+left\b',
        '\bspots?\s+left\s*[:\-]?\s*(?<spots>\d+)\b',
        '\bremaining\s+spots?\s*[:\-]?\s*(?<spots>\d+)\b',
        '\b(?<spots>\d+)\s+spots?\s+remaining\b'
    )

    foreach ($pattern in $spotPatterns) {
        $match = [regex]::Match(
            $text,
            $pattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($match.Success) {
            $spots = [int]$match.Groups['spots'].Value
            $noun = if ($spots -eq 1) { 'spot' } else { 'spots' }

            return [pscustomobject]@{
                SpotsLeft = $spots
                Status    = "$spots $noun left"
                Found     = $true
            }
        }
    }

    return [pscustomobject]@{
        SpotsLeft = $null
        Status    = 'Spots unavailable'
        Found     = $false
    }
}

function Get-CherryBreak {
    param(
        [Parameter(Mandatory)]
        [string]$ProductUrl
    )

    Write-Verbose "Checking product: $ProductUrl"

    try {
        $product = Get-ProductJson -ProductUrl $ProductUrl

        if ($product) {
            $title = $product.title
            $spotResult = Get-SpotsLeftFromProductJson -Product $product
        }
        else {
            $response = Invoke-CherryRequest `
                -Uri $ProductUrl `
                -MaximumAttempts 1
            $html = $response.Content

            $title = Get-ProductTitle -Html $html
            $spotResult = Get-SpotsLeft -Html $html
        }

        return [pscustomobject]@{
            Title     = $title
            SpotsLeft = $spotResult.SpotsLeft
            Status    = $spotResult.Status
            Url       = $ProductUrl
        }
    }
    catch {
        return [pscustomobject]@{
            Title     = 'Unable to load product'
            SpotsLeft = $null
            Status    = 'Request failed'
            Url       = $ProductUrl
        }
    }
}

function Remove-DateText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $cleanText = $Text

    # Remove weekday names when they form part of the advertised break date.
    $cleanText = $cleanText -replace '(?i)\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b', ' '

    # Remove dates written with month names, for example:
    # 24 July, 24th July, July 24, July 24th, and optional years.
    $months = 'Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?'

    # Remove an entire parenthesised date/time label, for example:
    # (Jul 27 4pm), (Jul 27 @ 4:00 PM), or (27 Jul - 4pm).
    $time = '\d{1,2}(?::\d{2})?\s*(?:am|pm)'
    $cleanText = $cleanText -replace "(?i)\(\s*(?:(?:$months)\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:$months))(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$time)?\s*\)", ' '

    $cleanText = $cleanText -replace "(?i)\b(?:$months)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$time)?\b", ' '
    $cleanText = $cleanText -replace "(?i)\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:$months)(?:,?\s+20\d{2})?(?:\s*(?:@|at|-)?\s*$time)?\b", ' '

    # Remove common numeric dates, including 24/07, 24-07-2026 and ISO dates.
    $cleanText = $cleanText -replace '(?<!\d)20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}(?!\d)', ' '
    $cleanText = $cleanText -replace '(?<!\d)\d{1,2}[-/.]\d{1,2}(?:[-/.](?:20)?\d{2})?(?!\d)', ' '

    # Remove standalone years and season ranges such as 2025, 2025-26 or 2025/26.
    $cleanText = $cleanText -replace '(?i)\b20\d{2}(?:[-/]\d{2,4})?\b', ' '

    return ($cleanText -replace '\s+', ' ').Trim()
}


function Get-DailyBreakName {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    # Daily break names may appear in standard or "Lil" variants. Preserve
    # the Lil prefix and also recognise Squadz as its own break name.
    $dailyNameMatch = [regex]::Match(
        $Title,
        '(?i)\b(?<lil>Lil\s+)?(?<name>Punterz|Teamz|Squadz|Derby|Slapperz)\b'
    )

    if (-not $dailyNameMatch.Success) {
        return $null
    }

    $name = switch ($dailyNameMatch.Groups['name'].Value.ToLowerInvariant()) {
        'punterz'  { 'Punterz' }
        'teamz'    { 'Teamz' }
        'squadz'   { 'Squadz' }
        'derby'    { 'Derby' }
        'slapperz' { 'Slapperz' }
    }

    if ($dailyNameMatch.Groups['lil'].Success) {
        return "Lil $name"
    }

    return $name
}

function Get-WeeklyBreakName {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    # Weekly break names are sometimes written loosely. Recognise common
    # singular/plural and z/s variants.
    $weeklyNameMatch = [regex]::Match(
        $Title,
        '(?i)\b(?<name>Machos?|Spenda(?:s|z)?|Punterz?|Slugger(?:s|z)?|Amigos?)\b'
    )

    if (-not $weeklyNameMatch.Success) {
        return $null
    }

    $rawName = $weeklyNameMatch.Groups['name'].Value.ToLowerInvariant()

    $name = switch -Regex ($rawName) {
        '^macho'   { 'Machos' }
        '^spenda'  { 'Spenda' }
        '^punter'  { 'Punterz' }
        '^slugger' { 'Sluggerz' }
        '^amigo'   { 'Amigos' }
    }

    return $name
}

function Get-FullBreakDescription {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $weeklyBreakName = Get-WeeklyBreakName -Title $Title
    if ($weeklyBreakName) {
        return $weeklyBreakName
    }

    # The five recurring daily breaks use their established short names.
    $dailyBreakName = Get-DailyBreakName -Title $Title
    if ($dailyBreakName) {
        return $dailyBreakName
    }

    # Keep the complete product/break description, but omit advertised dates
    # and metadata that is displayed separately later in the output line.
    $description = Remove-DateText -Text $Title

    # The break number and allocation type are appended separately so they do
    # not appear twice in the final output.
    $description = $description -replace '#\d+', ' '
    $description = $description -replace '(?i)\b(?:Wrestler\s+Team\s+Based|Team\s+Based|Pick\s+Your\s+Wrestlers?|PYW)\b', ' '
    $description = $description -replace '(?i)\b(?:Pick\s+Your\s+Players?|PYP)\b', ' '
    $description = $description -replace '(?i)\b(?:Pick\s+Your\s+Teams?|PYT)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Teams?|RT)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Wrestlers?|RW)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Spots?|RS)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Colou?rs?|RC)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Players?|RP)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Packs?|RPk)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Types?)\b', ' '
    $description = $description -replace '(?i)\b(?:Types?)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Characters?)\b', ' '
    $description = $description -replace '(?i)\b(?:Random\s+Wreslet)\b', ' '
    $description = $description -replace '(?i)\bOpening\b', ' '
    $description = $description -replace '(?i)\b(?<count>\d+)\s*-?\s*Box(?:es)?\b', '(${count})'

    # Clean separators and whitespace left behind by removed metadata.
    $middleDot = [regex]::Escape([string][char]0x30FB)
    $separatorChars = '\-\|' + $middleDot +
        [regex]::Escape([string][char]0x2013) +
        [regex]::Escape([string][char]0x2014)

    $description = $description -replace "\s*$middleDot\s*", ' '
    $description = $description -replace "[\s\p{Zs}]*[$separatorChars]+(?:[\s\p{Zs}]*[$separatorChars]+)*[\s\p{Zs}]*$", ' '
    $description = $description -replace "^[\s\p{Zs}]*[$separatorChars]+(?:[\s\p{Zs}]*[$separatorChars]+)*[\s\p{Zs}]*", ' '
    $description = $description -replace '\s+', ' '
    $description = $description.Trim()

    if (-not $description) {
        return 'Break'
    }

    return $description
}

function Test-DailyBreak {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    return $null -ne (Get-DailyBreakName -Title $Item.Title)
}

function Test-WeeklyBreak {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    return $null -ne (Get-WeeklyBreakName -Title $Item.Title)
}

function Test-DailyResultBreak {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    return (Test-DailyBreak -Item $Item) -and
        -not (Test-WeeklyBreak -Item $Item)
}

function Test-OpenRecurringBreak {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    return $null -ne $Item.SpotsLeft -and
        $Item.SpotsLeft -gt 0
}

function Get-SelectedRecurringBreaks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [switch]$IncludeDailies,

        [switch]$IncludeWeeklies
    )

    $selectedResults = New-Object `
        -TypeName 'System.Collections.Generic.List[object]'

    if ($IncludeDailies) {
        foreach ($item in @($Results | Where-Object {
                    (Test-DailyResultBreak -Item $_) -and
                    (Test-OpenRecurringBreak -Item $_)
                })) {
            [void]$selectedResults.Add($item)
        }
    }

    if ($IncludeWeeklies) {
        foreach ($item in @($Results | Where-Object {
                    (Test-WeeklyBreak -Item $_) -and
                    (Test-OpenRecurringBreak -Item $_)
                })) {
            [void]$selectedResults.Add($item)
        }
    }

    return $selectedResults.ToArray()
}

function Get-BreakSportEmoji {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    # Daily breaks keep the sport of their base name, including all Lil
    # variants. Squadz is an American-football break whether or not it has Lil.
    if ($Title -match '(?i)\b(?:Lil\s+)?(?:Punterz|Squadz)\b') {
        return [char]::ConvertFromUtf32(0x1F3C8) # American football
    }

    if ($Title -match '(?i)\b(?:Lil\s+)?Teamz\b') {
        return [char]::ConvertFromUtf32(0x1F3C0) # basketball
    }

    if ($Title -match '(?i)\b(?:Lil\s+)?Derby\b') {
        return [char]::ConvertFromUtf32(0x26BE) # baseball
    }

    if ($Title -match '(?i)\b(?:Lil\s+)?Slapperz\b') {
        return [char]::ConvertFromUtf32(0x1F3D2) # hockey stick and puck
    }

    # Check soccer before brand names such as Topps. Topps produces both
    # baseball and soccer products, so treating every Topps title as baseball
    # causes soccer breaks to display the baseball emoji.
    if ($Title -match '(?i)\b(Soccer|EPL|UCL|UEFA|FIFA|Premier League|Champions League|La Liga|LaLiga|Bundesliga|Serie A|Ligue 1|MLS|World Cup|Euro 20\d{2})\b') {
        return [char]::ConvertFromUtf32(0x26BD) # soccer ball
    }

    if ($Title -match '(?i)\b(NBA|Basketball)\b') {
        return [char]::ConvertFromUtf32(0x1F3C0) # basketball
    }

    if ($Title -match '(?i)\b(NFL|American Football|Gridiron)\b') {
        return [char]::ConvertFromUtf32(0x1F3C8) # American football
    }

    if ($Title -match '(?i)\b(NHL|Hockey)\b') {
        return [char]::ConvertFromUtf32(0x1F3D2) # hockey stick and puck
    }

    if ($Title -match '(?i)\b(Tennis|ATP|WTA)\b') {
        return [char]::ConvertFromUtf32(0x1F3BE) # tennis
    }

    if ($Title -match '(?i)\b(WWE|AEW|MLW|Wrestling|Wrestler|Wrestlers)\b') {
        return ([char]::ConvertFromUtf32(0x1F93C) + [char]::ConvertFromUtf32(0x200D) + [char]::ConvertFromUtf32(0x2642) + [char]::ConvertFromUtf32(0xFE0F)) # man wrestling
    }

    if ($Title -match '(?i)\b(MLB|Baseball|Bowman)\b') {
        return [char]::ConvertFromUtf32(0x26BE) # baseball
    }

    return ''
}

function Get-DayCollectionUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    return "$BaseUrl/collections/$Day"
}

function Get-DayProductsCollectionUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    return "$(Get-DayCollectionUrl -Day $Day)?sort=creation_date"
}

function Get-DayCollectionLine {
    param(
        [Parameter(Mandatory)]
        [string]$Day
    )

    return 'Tonights Live Openings (Plz Check Dates) -> {0}' -f `
        (Get-DayCollectionUrl -Day $Day)
}

function Normalize-BreakLine {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $middleDot = [regex]::Escape([string][char]0x30FB)
    $separatorChars = '\-\|' +
        [regex]::Escape([string][char]0x2013) +
        [regex]::Escape([string][char]0x2014)

    $line = $Line.Trim()
    $line = $line -replace "\s+[$separatorChars]+\s*$middleDot\s*(?=Random\s+President\b)", ' - '
    $line = $line -replace "\s+[$separatorChars]+\s*$middleDot\s*", ' '
    $line = $line -replace "\s*$middleDot\s*", ' '
    $line = $line -replace "\s+[$separatorChars]+\s+(?=(?:\S+\s+)?\((?:\?|\d+)\s+spots\))", ' '
    $line = $line -replace '\s{2,}', ' '

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

    $line = ('{0} {1} {2} {3}{4} -> {5}' -f `
        $Description,
        $SportEmoji,
        $SpotsText,
        $BreakNumber,
        $BreakTypeText,
        $UrlText)

    return Normalize-BreakLine -Line $line
}

function Format-BreakLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item,

        [switch]$YouTube
    )

    $uri = [uri]$Item.Url
    $urlText = "https://www.cherrycollectables.com.au$($uri.AbsolutePath)"
    $breakNumber = '#?'

    if ($Item.Title -match '#(?<number>\d+)') {
        $breakNumber = "#$($Matches['number'])"
    }

    $description = Get-FullBreakDescription -Title $Item.Title
    $sportEmoji = Get-BreakSportEmoji -Title $Item.Title

    $isNamedRecurringBreak = (Test-DailyBreak -Item $Item) -or
        (Test-WeeklyBreak -Item $Item)

    $spotsText = if ($null -eq $Item.SpotsLeft) {
        if ($isNamedRecurringBreak) {
            '(? spots left)'
        }
        else {
            '(? spots)'
        }
    }
    else {
        if ($isNamedRecurringBreak) {
            "($($Item.SpotsLeft) spots left)"
        }
        else {
            "($($Item.SpotsLeft) spots)"
        }
    }

    # Only show the compact suffix for alternative random allocation types.
    # For pick-your-spot style breaks, do not append anything.
    $breakTypeText = if ($Item.Title -match '(?i)\b(?:Random\s+Teams?|RT)\b') {
        ' - RT'
    }
    elseif ($Item.Title -match '(?i)\b(?:Random\s+Wrestlers?|RW)\b') {
        ' - RW'
    }
    elseif ($Item.Title -match '(?i)\b(?:Random\s+Spots?|RS)\b') {
        ' - RS'
    }
    elseif ($Item.Title -match '(?i)\b(?:Random\s+Colou?rs?|RC)\b') {
        ' - RC'
    }
    elseif ($Item.Title -match '(?i)\b(?:Random\s+Players?|RP)\b') {
        ' - RP'
    }
    elseif ($Item.Title -match '(?i)\b(?:Random\s+Packs?|RPk)\b') {
        ' - RPk'
    }
    else {
        ''
    }

    $line = Join-BreakLine `
        -Description $description `
        -SportEmoji $sportEmoji `
        -SpotsText $spotsText `
        -BreakNumber $breakNumber `
        -BreakTypeText $breakTypeText `
        -UrlText $urlText

    if ($YouTube -and $line.Length -gt 200) {
        $fixedLine = Join-BreakLine `
            -Description '' `
            -SportEmoji $sportEmoji `
            -SpotsText $spotsText `
            -BreakNumber $breakNumber `
            -BreakTypeText $breakTypeText `
            -UrlText $urlText

        $separatorLength = if ($fixedLine) { 1 } else { 0 }
        $descriptionLength = 200 - $fixedLine.Length - $separatorLength

        if ($descriptionLength -lt 0) {
            $descriptionLength = 0
        }

        if ($description.Length -gt $descriptionLength) {
            $description = $description.Substring(0, $descriptionLength).Trim()
        }

        $line = Join-BreakLine `
            -Description $description `
            -SportEmoji $sportEmoji `
            -SpotsText $spotsText `
            -BreakNumber $breakNumber `
            -BreakTypeText $breakTypeText `
            -UrlText $urlText
    }

    return $line
}

function Get-BreakResultGroups {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $dailyResults = @(
        $Results |
            Where-Object { Test-DailyResultBreak -Item $_ }
    )

    $weeklyResults = @(
        $Results |
            Where-Object { Test-WeeklyBreak -Item $_ }
    )

    $otherResults = @(
        $Results |
            Where-Object {
                -not (Test-DailyBreak -Item $_) -and
                -not (Test-WeeklyBreak -Item $_)
            }
    )

    return [pscustomobject]@{
        Dailies  = $dailyResults
        Weeklies = $weeklyResults
        Other    = $otherResults
    }
}

function Write-BreakResultLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item,

        [switch]$YouTube
    )

    $statusColour = switch ($Item.SpotsLeft) {
        0       { 'DarkGray' }
        { $_ -le 3 }  { 'Red' }
        { $_ -le 10 } { 'Yellow' }
        default { 'Green' }
    }

    $line = Format-BreakLine `
        -Item $Item `
        -YouTube:$YouTube

    Write-Host $line -ForegroundColor $statusColour
}

function Show-BreakResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Day,

        [switch]$YouTube,

        [switch]$IncludeDayCollectionLink
    )

    $sydneyDate = Get-SydneyDate
    $targetDate = Get-TargetDate -Day $Day

    Write-Host ''
    Write-Host (
        'Cherry break check - {0}, {1} (checked {2})' -f
        $Day,
        $targetDate.ToString('dd MMM yyyy'),
        $sydneyDate.ToString('dd MMM yyyy HH:mm')
    ) -ForegroundColor Cyan

    if ($IncludeDayCollectionLink) {
        Write-Host (Get-DayCollectionLine -Day $Day) -ForegroundColor Cyan
    }

    Write-Host ''

    if (-not $Results) {
        Write-Host 'No matching breaks were found.' -ForegroundColor Yellow
        return
    }

    $groups = Get-BreakResultGroups -Results $Results

    if ($groups.Dailies) {
        Write-Host 'Dailies' -ForegroundColor Cyan

        foreach ($item in $groups.Dailies) {
            Write-BreakResultLine `
                -Item $item `
                -YouTube:$YouTube
        }

        if ($groups.Weeklies -or $groups.Other) {
            Write-Host ''
        }
    }

    if ($groups.Weeklies) {
        Write-Host 'Weeklies' -ForegroundColor Cyan

        foreach ($item in $groups.Weeklies) {
            Write-BreakResultLine `
                -Item $item `
                -YouTube:$YouTube
        }

        if ($groups.Other) {
            Write-Host ''
        }
    }

    if ($groups.Other) {
        Write-Host 'Other Breaks' -ForegroundColor Cyan

        foreach ($item in $groups.Other) {
            Write-BreakResultLine `
                -Item $item `
                -YouTube:$YouTube
        }
    }
}

function Resolve-OutputPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $PSScriptRoot $Path
}

function Save-TextResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Day,

        [switch]$YouTube,

        [switch]$IncludeDayCollectionLink
    )

    if (-not $OutputPath) {
        return
    }

    $resolvedPath = Resolve-OutputPath -Path $OutputPath
    $targetDate = Get-TargetDate -Day $Day
    $lines = New-Object `
        -TypeName 'System.Collections.Generic.List[string]'

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
        $groups = Get-BreakResultGroups -Results $Results

        if ($groups.Dailies) {
            $lines.Add('Dailies')

            foreach ($item in $groups.Dailies) {
                $lines.Add(
                    (Format-BreakLine `
                        -Item $item `
                        -YouTube:$YouTube)
                )
            }

            if ($groups.Weeklies -or $groups.Other) {
                $lines.Add('')
            }
        }

        if ($groups.Weeklies) {
            $lines.Add('Weeklies')

            foreach ($item in $groups.Weeklies) {
                $lines.Add(
                    (Format-BreakLine `
                        -Item $item `
                        -YouTube:$YouTube)
                )
            }

            if ($groups.Other) {
                $lines.Add('')
            }
        }

        if ($groups.Other) {
            $lines.Add('Other Breaks')

            foreach ($item in $groups.Other) {
                $lines.Add(
                    (Format-BreakLine `
                        -Item $item `
                        -YouTube:$YouTube)
                )
            }
        }
    }

    $directory = Split-Path -Parent $resolvedPath

    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item `
            -ItemType Directory `
            -Path $directory `
            -Force |
            Out-Null
    }

    $lines |
        Set-Content `
            -LiteralPath $resolvedPath `
            -Encoding utf8

    Write-Host (
        "TXT FILE UPDATED SUCCESSFULLY: $resolvedPath ($($Results.Count) result(s), overwritten)"
    ) -ForegroundColor Green
}

function Get-TwitchChatLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item,

        [switch]$YouTube
    )

    return Format-BreakLine `
        -Item $Item `
        -YouTube:$YouTube
}

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

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 1000
    )

    $lines = New-Object `
        -TypeName 'System.Collections.Generic.List[string]'

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $remainingMilliseconds = [int][Math]::Max(
            100,
            ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        )

        try {
            $Reader.BaseStream.ReadTimeout = [Math]::Min(
                1000,
                $remainingMilliseconds
            )

            $line = $Reader.ReadLine()

            if ($null -eq $line) {
                break
            }

            $lines.Add($line)
            Write-Verbose "Twitch IRC <- $(Get-RedactedTwitchIrcLine -Line $line)"
        }
        catch [System.IO.IOException] {
            break
        }
    }

    return @($lines)
}

function Test-TwitchIrcLoginAccepted {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    return [bool](
        $Lines |
            Where-Object {
                $_ -match '(^| )001 ' -or
                $_ -match '^:tmi\.twitch\.tv 001 '
            } |
            Select-Object -First 1
    )
}

function Get-TwitchIrcFailureLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    return $Lines |
        Where-Object {
            $_ -match 'Login authentication failed' -or
            $_ -match 'Improperly formatted auth' -or
            $_ -match 'Error logging in' -or
            $_ -match '^:tmi\.twitch\.tv NOTICE \* :'
        } |
        Select-Object -First 1
}

function Test-TwitchIrcJoinAccepted {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Channel
    )

    return [bool](
        $Lines |
            Where-Object {
                $_ -match " JOIN #$([regex]::Escape($Channel))$" -or
                $_ -match " ROOMSTATE #$([regex]::Escape($Channel))$" -or
                $_ -match " 353 .* #$([regex]::Escape($Channel)) :"
            } |
            Select-Object -First 1
    )
}

function Get-TwitchIrcNoticeLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    return @(
        $Lines |
            Where-Object { $_ -match ' NOTICE ' }
    )
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
        [int]$DelaySeconds = 2
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

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $sslStream = $null
    $reader = $null
    $writer = $null

    try {
        Write-Host "Connecting to Twitch IRC as $cleanUser for #$cleanChannel..." -ForegroundColor Cyan
        $tcpClient.Connect('irc.chat.twitch.tv', 6697)

        $sslStream = New-Object `
            System.Net.Security.SslStream(
                $tcpClient.GetStream(),
                $false,
                ({ $true } -as [Net.Security.RemoteCertificateValidationCallback])
            )

        $sslStream.AuthenticateAsClient('irc.chat.twitch.tv')

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $reader = New-Object `
            System.IO.StreamReader(
                $sslStream,
                $utf8NoBom
            )

        $writer = New-Object `
            System.IO.StreamWriter(
                $sslStream,
                $utf8NoBom
            )
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
            -TimeoutMilliseconds 5000

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
            -TimeoutMilliseconds 5000

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

        foreach ($message in $Messages) {
            Write-Verbose "Twitch IRC -> PRIVMSG #$cleanChannel :$message"
            $writer.WriteLine("PRIVMSG #$cleanChannel :$message")

            $messageResponseLines = Read-TwitchIrcLines `
                -Reader $reader `
                -TimeoutMilliseconds 1000

            $noticeLines = Get-TwitchIrcNoticeLines -Lines $messageResponseLines

            if ($noticeLines) {
                foreach ($noticeLine in $noticeLines) {
                    Write-Warning (
                        "Twitch IRC notice after message: $(Get-RedactedTwitchIrcLine -Line $noticeLine)"
                    )
                }
            }
            else {
                Write-Host "Submitted Twitch chat message: $message" -ForegroundColor Green
            }

            Start-Sleep -Seconds $DelaySeconds
        }
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }

        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $sslStream) {
            $sslStream.Dispose()
        }

        $tcpClient.Dispose()
    }
}

function Publish-TwitchResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [switch]$YouTube
    )

    if (-not $Twitch) {
        return
    }

    $missingSettings = @()

    if (-not $TwitchChannel) {
        $missingSettings += 'TWITCH_CHANNEL'
    }

    if (-not $TwitchUser) {
        $missingSettings += 'TWITCH_USER'
    }

    if (-not $TwitchOAuthToken) {
        $missingSettings += 'TWITCH_OAUTH_TOKEN'
    }

    if ($missingSettings) {
        throw (
            'Twitch sending was requested, but these setting(s) are missing: ' +
            ($missingSettings -join ', ')
        )
    }

    $includeDailies = $Dailies -or -not $Weeklies
    $messages = @(
        Get-SelectedRecurringBreaks `
            -Results $Results `
            -IncludeDailies:$includeDailies `
            -IncludeWeeklies:$Weeklies |
            ForEach-Object {
                Get-TwitchChatLine `
                    -Item $_ `
                    -YouTube:$YouTube
            }
    )

    Send-TwitchChatMessages `
        -Channel $TwitchChannel `
        -User $TwitchUser `
        -OAuthToken $TwitchOAuthToken `
        -Messages $messages `
        -DelaySeconds $TwitchMessageDelaySeconds
}

function Invoke-BreakCheck {
    $targetDay = Get-TargetDay -RequestedDay $Day
    $targetDate = Get-TargetDate -Day $targetDay
    $isWeeklyOnlySearch = $Weeklies -and -not $Dailies

    $results = New-Object `
        -TypeName 'System.Collections.Generic.List[object]'

    Write-Host ''
    Write-Host 'Checking all breaks...' -ForegroundColor Cyan

    try {
        $productLinkSet = New-Object `
            -TypeName 'System.Collections.Generic.HashSet[string]' `
            -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

        if (-not $isWeeklyOnlySearch) {
            $collectionUrl = Get-CollectionUrl `
                -Day $targetDay

            Write-Verbose "Collection URL: $collectionUrl"

            $productLinks = @(
                Get-ProductLinks `
                    -CollectionUrl $collectionUrl
            )

            foreach ($productUrl in $productLinks) {
                [void]$productLinkSet.Add($productUrl)
            }

            $dayProductsCollectionUrl = Get-DayProductsCollectionUrl `
                -Day $targetDay

            Write-Verbose (
                "Checking day collection for live openings matching " +
                "$targetDay`: $dayProductsCollectionUrl"
            )

            $dayProductLinks = @(
                Get-ProductLinks `
                    -CollectionUrl $dayProductsCollectionUrl
            )

            foreach ($productUrl in $dayProductLinks) {
                [void]$productLinkSet.Add($productUrl)
            }
        }

        $fallbackCollectionUrl = Get-UnfilteredCollectionUrl
        Write-Verbose (
            "Checking unfiltered collection for URL dates matching " +
            "$targetDay`: $fallbackCollectionUrl"
        )

        $fallbackProductLinks = @(
            Get-ProductLinks `
                -CollectionUrl $fallbackCollectionUrl
        )

        foreach ($productUrl in $fallbackProductLinks) {
            if ($Weeklies -or
                (Test-ProductMatchesDayFallback `
                    -ProductUrl $productUrl `
                    -Day $targetDay `
                    -TargetDate $targetDate)) {
                [void]$productLinkSet.Add($productUrl)
            }
        }

        $productLinks = @($productLinkSet | Sort-Object)

        Write-Host (
            "Found $($productLinks.Count) product link(s)."
        )

        foreach ($productUrl in $productLinks) {
            $break = Get-CherryBreak `
                -ProductUrl $productUrl

            $isWeeklySearchMatch = $Weeklies -and
                (Test-WeeklyBreak -Item $break)
            $titleDate = Get-TextBreakDate -Text $break.Title

            if (-not $isWeeklySearchMatch -and
                $titleDate -and
                $titleDate -ne $targetDate.Date) {
                Write-Verbose (
                    "Skipping '$($break.Title)' because its title date " +
                    "$($titleDate.ToString('dd MMM yyyy')) does not match " +
                    "$($targetDate.ToString('dd MMM yyyy'))."
                )

                continue
            }

            if (-not $isWeeklySearchMatch -and -not $titleDate) {
                $uri = [uri]$productUrl
                $urlDate = Get-TextBreakDate -Text $uri.AbsolutePath

                if ($urlDate -and $urlDate -ne $targetDate.Date) {
                    Write-Verbose (
                        "Skipping '$($break.Title)' because its URL date " +
                        "$($urlDate.ToString('dd MMM yyyy')) does not match " +
                        "$($targetDate.ToString('dd MMM yyyy'))."
                    )

                    continue
                }
            }

            [void]$results.Add($break)
        }
    }
    catch {
        Write-Warning (
            "Could not check breaks collection: " +
            $_.Exception.Message
        )
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
        -YouTube:$YouTube `
        -IncludeDayCollectionLink:$DayWasExplicitlyRequested

    Save-TextResults `
        -Results $allResults `
        -Day $targetDay `
        -YouTube:$YouTube `
        -IncludeDayCollectionLink:$DayWasExplicitlyRequested

    Publish-TwitchResults `
        -Results $allResults `
        -YouTube:$YouTube

    return $allResults
}

try {
    $null = Invoke-BreakCheck
}
catch {
    Write-Error "Break check failed: $($_.Exception.Message)"
}
