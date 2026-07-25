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

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        [string]$Uri
    )

    $maximumAttempts = 3

    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            return Invoke-WebRequest `
                -Uri $Uri `
                -Headers $Headers `
                -MaximumRedirection 5 `
                -TimeoutSec 45 `
                -UseBasicParsing
        }
        catch {
            if ($attempt -eq $maximumAttempts) {
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
        $jsonResponse = Invoke-CherryRequest -Uri $productJsonUrl
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

function Get-ProductLinks {
    param(
        [Parameter(Mandatory)]
        [string]$CollectionUrl
    )

    Write-Verbose "Loading collection page: $CollectionUrl"

    $response = Invoke-CherryRequest -Uri $CollectionUrl
    $html = $response.Content

    $fastSimonGridUrl = Get-FastSimonGridUrl `
        -Html $html `
        -CollectionUrl $CollectionUrl

    $productUrls = New-Object `
        -TypeName 'System.Collections.Generic.HashSet[string]' `
        -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

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
                $href = $match.Groups['href'].Value

                $href = $href `
                    -replace '\\u0026', '&' `
                    -replace '\\/', '/'

                if ($href -notmatch '/products/') {
                    continue
                }

                $absoluteUrl = ConvertTo-AbsoluteProductUrl -Href $href
                $canonicalUrl = Get-CanonicalProductUrl -Url $absoluteUrl

                if ($productUrls.Add($canonicalUrl)) {
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
            $response = Invoke-CherryRequest -Uri $ProductUrl
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

function Get-FullBreakDescription {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

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

function Format-BreakLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    $uri = [uri]$Item.Url
    $urlText = "https://www.cherrycollectables.com.au$($uri.AbsolutePath)"
    $breakNumber = '#?'

    if ($Item.Title -match '#(?<number>\d+)') {
        $breakNumber = "#$($Matches['number'])"
    }

    $description = Get-FullBreakDescription -Title $Item.Title
    $sportEmoji = Get-BreakSportEmoji -Title $Item.Title

    # A number in parentheses is the number of spots, without the word
    # "left", matching the shorter preferred output style.
    $spotsText = if ($null -eq $Item.SpotsLeft) {
        '(? spots)'
    }
    else {
        "($($Item.SpotsLeft) spots)"
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

    $line = ('{0} {1} {2} {3}{4} -> {5}' -f `
        $description,
        $sportEmoji,
        $spotsText,
        $breakNumber,
        $breakTypeText,
        $urlText).Trim()

    $middleDot = [regex]::Escape([string][char]0x30FB)
    $separatorChars = '\-\|' +
        [regex]::Escape([string][char]0x2013) +
        [regex]::Escape([string][char]0x2014)

    $line = $line -replace "\s+[$separatorChars]+\s*$middleDot\s*(?=Random\s+President\b)", ' - '
    $line = $line -replace "\s+[$separatorChars]+\s*$middleDot\s*", ' '
    $line = $line -replace "\s*$middleDot\s*", ' '
    $line = $line -replace "\s+[$separatorChars]+\s+(?=(?:\S+\s+)?\((?:\?|\d+)\s+spots\))", ' '
    $line = $line -replace '\s{2,}', ' '

    return $line
}

function Show-BreakResults {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Day
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

    Write-Host ''

    if (-not $Results) {
        Write-Host 'No matching breaks were found.' -ForegroundColor Yellow
        return
    }

    foreach ($item in $Results) {
        $statusColour = switch ($item.SpotsLeft) {
            0       { 'DarkGray' }
            { $_ -le 3 }  { 'Red' }
            { $_ -le 10 } { 'Yellow' }
            default { 'Green' }
        }

        $line = Format-BreakLine -Item $item

        Write-Host $line -ForegroundColor $statusColour
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
        [string]$Day
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

    if (-not $Results) {
        $lines.Add('No matching breaks were found.')
    }
    else {
        foreach ($item in $Results) {
            $lines.Add(
                (Format-BreakLine -Item $item)
            )
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

function Invoke-BreakCheck {
    $targetDay = Get-TargetDay -RequestedDay $Day
    $targetDate = Get-TargetDate -Day $targetDay

    $results = New-Object `
        -TypeName 'System.Collections.Generic.List[object]'

    $collectionUrl = Get-CollectionUrl `
        -Day $targetDay

    Write-Host ''
    Write-Host 'Checking all breaks...' -ForegroundColor Cyan

    Write-Verbose "Collection URL: $collectionUrl"

    try {
        $productLinks = @(
            Get-ProductLinks `
                -CollectionUrl $collectionUrl
        )

        $productLinkSet = New-Object `
            -TypeName 'System.Collections.Generic.HashSet[string]' `
            -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($productUrl in $productLinks) {
            [void]$productLinkSet.Add($productUrl)
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
            if (Test-ProductMatchesDayFallback `
                    -ProductUrl $productUrl `
                    -Day $targetDay `
                    -TargetDate $targetDate) {
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

            $titleDate = Get-TextBreakDate -Text $break.Title

            if ($titleDate -and $titleDate -ne $targetDate.Date) {
                Write-Verbose (
                    "Skipping '$($break.Title)' because its title date " +
                    "$($titleDate.ToString('dd MMM yyyy')) does not match " +
                    "$($targetDate.ToString('dd MMM yyyy'))."
                )

                continue
            }

            if (-not $titleDate) {
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

    Show-BreakResults `
        -Results $allResults `
        -Day $targetDay

    Save-TextResults `
        -Results $allResults `
        -Day $targetDay

    return $allResults
}

try {
    $null = Invoke-BreakCheck
}
catch {
    Write-Error "Break check failed: $($_.Exception.Message)"
}
