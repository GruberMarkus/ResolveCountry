# Requires -Version 5.1

# Compile C# Levenshtein distance function (Cross-platform and PS5.1 safe)
if (-not ('FuzzyMatcher' -as [type])) {
    Add-Type -TypeDefinition @'
    public class FuzzyMatcher {
        public static int Levenshtein(string s, string t) {
            if (string.IsNullOrEmpty(s)) return string.IsNullOrEmpty(t) ? 0 : t.Length;
            if (string.IsNullOrEmpty(t)) return s.Length;

            s = s.ToLowerInvariant();
            t = t.ToLowerInvariant();

            int[,] d = new int[s.Length + 1, t.Length + 1];
            for (int i = 0; i <= s.Length; i++) d[i, 0] = i;
            for (int j = 0; j <= t.Length; j++) d[0, j] = j;

            for (int i = 1; i <= s.Length; i++) {
                for (int j = 1; j <= t.Length; j++) {
                    int cost = (s[i - 1] == t[j - 1]) ? 0 : 1;
                    d[i, j] = System.Math.Min(
                        System.Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1),
                        d[i - 1, j - 1] + cost
                    );
                }
            }
            return d[s.Length, t.Length];
        }
    }
'@
}

# In-Memory Cache Variable Definition (Module Scope)
$script:CountryLookupCache = $null

# Text Normalization Helper (Internal)
function ConvertTo-NormalizedText ([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $decomposed = $text.Normalize([System.Text.NormalizationForm]::FormKD)
    $noDiacritics = $decomposed -replace '\p{M}', ''
    $noPunctuation = $noDiacritics -replace '[\p{P}\p{S}\p{C}]', ' '
    return ($noPunctuation -replace '\s+', ' ').Trim().ToLowerInvariant()
}

# Helper to read and decompress cache file into Hashtable (Internal)
function Import-CompressedCountryCache ([string]$Path) {
    $fileStream = [System.IO.File]::OpenRead($Path)
    $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = [System.IO.StreamReader]::new($gzipStream, [System.Text.Encoding]::UTF8)

    try {
        $json = $reader.ReadToEnd()
        $rawObject = $json | ConvertFrom-Json

        # Convert PSCustomObject back to Hashtable for identical key lookup performance
        $hash = @{}
        foreach ($prop in $rawObject.psobject.properties) {
            $hash[$prop.Name] = $prop.Value
        }
        return $hash
    } finally {
        $reader.Dispose()
        $gzipStream.Dispose()
        $fileStream.Dispose()
    }
}

# Data Download and Compressed Cache Generation Function (Public)
function Update-ResolveCountryData {
    [CmdletBinding()]
    param (
        [string]$CacheFilePath = (Join-Path -Path $PSScriptRoot -ChildPath 'ResolveCountry.Data.json.gz')
    )

    $tempDir = New-Item -Path ([System.IO.Path]::GetTempPath()) -Name (New-Guid).Guid -ItemType Directory
    $originalLocation = Get-Location
    Set-Location -Path $tempDir.FullName

    try {
        Write-Verbose 'Downloading countries.json...'
        # -UseBasicParsing is necessary for PS5.1 compatibility without IE engine
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/mledoze/countries/refs/heads/master/dist/countries.json' -OutFile 'countries.json' -UseBasicParsing

        $ImportCountries = Get-Content 'countries.json' -Raw | ConvertFrom-Json
        $Result = @{}

        foreach ($ImportCountry in $ImportCountries) {
            if ([string]::IsNullOrWhiteSpace($ImportCountry.cca2)) { continue }

            # Extract native names (Null-safe for PS 5.1)
            $nativeValues = @()
            if ($null -ne $ImportCountry.name.native) {
                $nativeValues = foreach ($nat in $ImportCountry.name.native.psobject.properties) {
                    $nat.Value.official
                    $nat.Value.common
                }
            }

            # Extract built-in translations (Null-safe for PS 5.1)
            $translationValues = @()
            if ($null -ne $ImportCountry.translations) {
                $translationValues = foreach ($trans in $ImportCountry.translations.psobject.properties) {
                    $trans.Value.official
                    $trans.Value.common
                }
            }

            # Build unified lookup array
            $ImportCountryUniqueValues = @(
                $ImportCountry.name.official
                $ImportCountry.name.common
                $nativeValues
                $ImportCountry.cca2
                $ImportCountry.cca3
                $ImportCountry.ccn3
                $ImportCountry.altSpellings
                $translationValues
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique

            $Result["$($ImportCountry.cca2)"] = [pscustomobject]@{
                UniqueValues  = $ImportCountryUniqueValues
                CountryObject = $ImportCountry
            }
        }

        # Save minified, Gzip-compressed JSON
        $json = $Result | ConvertTo-Json -Depth 100 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $fileStream = [System.IO.File]::Create($CacheFilePath)
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionLevel]::Optimal)
        try {
            $gzipStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $gzipStream.Dispose()
            $fileStream.Dispose()
        }

        Write-Verbose "Cache saved to compressed JSON: $CacheFilePath"
        return $Result
    } finally {
        Set-Location -Path $originalLocation.Path
        Remove-Item -Path $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Search Function with Compressed Disk Cache Integration (Public)
function Resolve-Country {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SearchQuery,

        [Parameter(Position = 1)]
        [ValidateSet(
            'cca2',
            'cca3',
            'ccn3',
            'name.common',
            'name.native.common',
            'name.native.official',
            'name.official',
            'tld',
            'country'
        )]
        [string]$ReturnType = 'cca2',

        [Parameter()]
        [switch]$Reload
    )

    $cacheFilePath = Join-Path -Path $PSScriptRoot -ChildPath 'ResolveCountry.Data.json.gz'

    # Fallback to reload if the cache is empty or forcefully requested
    if ($Reload -or $null -eq $script:CountryLookupCache) {
        if (-not $Reload -and (Test-Path -Path $cacheFilePath)) {
            Write-Verbose 'Loading country lookup data from compressed JSON cache...'
            $script:CountryLookupCache = Import-CompressedCountryCache -Path $cacheFilePath
        } else {
            Write-Verbose 'Generating country lookup data...'
            $script:CountryLookupCache = Update-ResolveCountryData -CacheFilePath $cacheFilePath
        }
    }

    $LookupTable = $script:CountryLookupCache

    if ([string]::IsNullOrWhiteSpace($SearchQuery)) { return $null }

    $CleanQuery = ConvertTo-NormalizedText $SearchQuery
    $MatchedKey = $null

    # Stage 1: Exact / Case-Insensitive Search
    $FoundMatches = $LookupTable.GetEnumerator() | Where-Object {
        $null -ne $_.Value.UniqueValues -and $_.Value.UniqueValues -icontains $SearchQuery
    }

    if ($FoundMatches) {
        $MatchedKey = ($FoundMatches | Select-Object -First 1).Key
    } else {
        # Stage 2: Normalized Exact Search
        $FoundMatches = $LookupTable.GetEnumerator() | Where-Object {
            $uniqueVals = $_.Value.UniqueValues
            if ($null -eq $uniqueVals) { return $false }

            foreach ($val in $uniqueVals) {
                if ((ConvertTo-NormalizedText $val) -eq $CleanQuery) { return $true }
            }
            return $false
        }

        if ($FoundMatches) {
            $MatchedKey = ($FoundMatches | Select-Object -First 1).Key
        } else {
            # Stage 3: Token-Aware Fuzzy Search
            $MaxErrorRate = 0.25
            $MaxDistance = [Math]::Max(1, [Math]::Ceiling($CleanQuery.Length * $MaxErrorRate))

            $MatchResults = foreach ($entry in $LookupTable.GetEnumerator()) {
                $uniqueVals = $entry.Value.UniqueValues
                if ($null -eq $uniqueVals) { continue }

                $bestDistForCountry = 999

                foreach ($val in $uniqueVals) {
                    $cleanAlias = ConvertTo-NormalizedText $val
                    if ([string]::IsNullOrWhiteSpace($cleanAlias)) { continue }

                    $dist = [FuzzyMatcher]::Levenshtein($CleanQuery, $cleanAlias)
                    if ($dist -lt $bestDistForCountry) {
                        $bestDistForCountry = $dist
                    }

                    $tokens = $cleanAlias -split ' '
                    if ($tokens.Count -gt 1) {
                        foreach ($token in $tokens) {
                            $tokenDist = [FuzzyMatcher]::Levenshtein($CleanQuery, $token)
                            if ($tokenDist -lt $bestDistForCountry) {
                                $bestDistForCountry = $tokenDist
                            }
                        }
                    }
                }

                if ($bestDistForCountry -le $MaxDistance) {
                    [PSCustomObject]@{
                        Key      = $entry.Key
                        Distance = $bestDistForCountry
                    }
                }
            }

            $BestMatch = $MatchResults | Sort-Object Distance | Select-Object -First 1
            if ($BestMatch) {
                $MatchedKey = $BestMatch.Key
            }
        }
    }

    if (-not $MatchedKey) { return $null }

    # Map matched key to requested ReturnType
    $country = $LookupTable[$MatchedKey].CountryObject
    switch ($ReturnType) {
        'cca2' { return $country.cca2 }
        'cca3' { return $country.cca3 }
        'ccn3' { return $country.ccn3 }
        'name.common' { return $country.name.common }
        'name.native.common' { return ($country.name.native.psobject.properties | Select-Object -First 1).Value.common }
        'name.native.official' { return ($country.name.native.psobject.properties | Select-Object -First 1).Value.official }
        'name.official' { return $country.name.official }
        'tld' { return $country.tld }
        'country' { return $country }
    }
}

# ==========================================
# MODULE INITIALIZATION (RUNS ON IMPORT)
# ==========================================

# Export only the public functions; helper functions remain internal to the module
Export-ModuleMember -Function Resolve-Country, Update-ResolveCountryData
