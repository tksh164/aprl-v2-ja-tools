#Requires -Version 7

param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]] $RecommendationYamlFilePath,

    [Parameter(Mandatory = $true)]
    [string] $TranslateFrom,

    [Parameter(Mandatory = $true)]
    [string] $TranslateTo,

    [Parameter(Mandatory = $true)]
    [string] $ApiKey,

    [Parameter(Mandatory = $true)]
    [string] $Location,

    [Parameter(Mandatory = $false)]
    [string] $ApiEndpoint = 'https://api.cognitive.microsofttranslator.com/',

    [Parameter(Mandatory = $false)]
    [switch] $Overwrite
)

begin {
    $ErrorActionPreference = 'Stop'

    function Invoke-RecommendationYamlTranslation {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string] $YamlFilePath,

            [Parameter(Mandatory = $true)]
            [string] $TranslateFrom,

            [Parameter(Mandatory = $true)]
            [string] $TranslateTo,

            [Parameter(Mandatory = $true)]
            [string] $ApiKey,

            [Parameter(Mandatory = $true)]
            [string] $Location,

            [Parameter(Mandatory = $true)]
            [string] $ApiEndpoint
        )

        # The properties that need to be translated.
        $targetPropertyNames = @(
            'description',
            'potentialBenefits',
            'longDescription'
        )

        $yamlLines = Get-Content -Encoding utf8 -LiteralPath $yamlFilePath

        # NOTE: Use line by line processing approach to minimize differences as text.
        $translatedYamlBuilder = New-Object -TypeName 'System.Text.StringBuilder'
        $currentLineNum = 0
        $sourceTextPlaceholderPairs = @()
        while ($currentLineNum -lt $yamlLines.Length) {
            $lineProperty = Get-YamlLineProperty -Line $yamlLines[$currentLineNum]
            $shouldTranslateSingleLineValue = (-not [string]::IsNullOrWhiteSpace($lineProperty.TranslateChunk)) -and ($targetPropertyNames -contains $lineProperty.PropertyName)

            if ($shouldTranslateSingleLineValue -or $lineProperty.IsPartOfMultiline) {
                # Hold the text to translate and placeholder pairs to reduce the number of API calls.
                $stpPair = New-SourceTextPlaceholderPair -TextToTranslate $lineProperty.TranslateChunk
                $sourceTextPlaceholderPairs += $stpPair
                [void] $translatedYamlBuilder.AppendLine($lineProperty.NonTranslateChunk + $stpPair.Placeholder)
            }
            else {
                [void] $translatedYamlBuilder.AppendLine($lineProperty.Line)
            }
            $currentLineNum++
        }

        # Create a request body for the translation API call.
        $requestBodyContent = @()
        $requestBodyContent += foreach ($pair in $sourceTextPlaceholderPairs) {
            @{ 'Text' = $pair.TextToTranslate }
        }

        # Call the translation API.
        $params = @{
            RequestBody   = $requestBodyContent | ConvertTo-Json
            TranslateFrom = $TranslateFrom
            TranslateTo   = $TranslateTo
            ApiKey        = $ApiKey
            Location      = $Location
            ApiEndpoint   = $ApiEndpoint
        }
        $translatedResult = Invoke-Translation @params

        # Replace the placeholders with the translated texts.
        $translatedYaml = $translatedYamlBuilder.ToString()
        for ($i = 0; $i -lt $translatedResult.translations.Length; $i++) {
            $translatedYaml = $translatedYaml.Replace($sourceTextPlaceholderPairs[$i].Placeholder, $translatedResult.translations[$i].text)
        }

        # Remove the last newline character to respect the original count of newline characters.
        $translatedYaml = $translatedYaml.Substring(0, $translatedYaml.Length - [System.Environment]::NewLine.Length)

        return $translatedYaml
    }

    function Get-YamlLineProperty {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)][AllowEmptyString()]
            [string] $Line
        )

        $result = [PSCustomObject] @{
            Line              = $Line
            PropertyName      = $null
            IsPartOfMultiline = $false
            NonTranslateChunk = $null
            TranslateChunk    = $null
        }

        if ([string]::IsNullOrWhiteSpace($Line)) {
            return $result
        }

        if ($Line -match '^\s*[\-]*\s*([^:]+)\:\s*[\|]*.*$') {
            $result.PropertyName = $Matches[1]
        }
        else {
            $result.IsPartOfMultiline = $true
        }

        if ($result.IsPartOfMultiline) {
            if ($Line -match '^(\s*)(.+)$') {
                $result.NonTranslateChunk = $Matches[1]
                $result.TranslateChunk = $Matches[2]
            }
            else {
                throw 'Unexpected line format as a part of multi-lines: "{0}"' -f $Line
            }
        }
        else {
            if ($Line -match '^(\s*[\-]*\s*[^:]+\:\s*[\|]*)(.*)$') {
                $result.NonTranslateChunk = $Matches[1]
                $result.TranslateChunk = $Matches[2]
            }
            else {
                throw 'Unexpected line format as a single line: "{0}"' -f $Line
            }
        }
        return $result
    }

    function New-SourceTextPlaceholderPair {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string] $TextToTranslate
        )

        return [PSCustomObject] @{
            TextToTranslate = $TextToTranslate
            Placeholder     = '{{{' + (New-Guid).ToString() + '}}}'
        }
    }

    function Invoke-Translation {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string] $RequestBody,

            [Parameter(Mandatory = $true)]
            [string] $TranslateFrom,

            [Parameter(Mandatory = $true)]
            [string] $TranslateTo,

            [Parameter(Mandatory = $true)]
            [string] $ApiKey,
        
            [Parameter(Mandatory = $true)]
            [string] $Location,
        
            [Parameter(Mandatory = $true)]
            [string] $ApiEndpoint
        )
    
        $params = @{
            Method  = 'Post'
            Uri     = '{0}/translate?api-version=3.0&textType=plain&from={1}&to={2}' -f $ApiEndpoint, $TranslateFrom, $TranslateTo
            Headers = @{
                'Content-Type'                 = 'application/json'
                'Ocp-Apim-Subscription-Key'    = $ApiKey
                'Ocp-Apim-Subscription-Region' = $Location
            }
            Body    = $RequestBody
        }

        $maxAttempts = 3
        $waitSeconds = 15
        for ($attempts = 0; $attempts -lt $maxAttempts; $attempts++) {
            try {
                $result = Invoke-RestMethod @params
            }
            catch {
                if (($_.Exception -is [System.Net.Http.HttpRequestException]) -and ($_.Exception.Message -like '*established connection failed*')) {
                    Write-Host -Object ('Failed the translator API call. Will retrying after waiting {0} seconds...' -f $waitSeconds) -ForegroundColor Yellow
                    Start-Sleep -Seconds $waitSeconds
                }
                else {
                    throw $_
                }
            }
        }
        return $result
    }

    function New-OutputYamlFileName {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string] $YamlFilePath
        )

        $parentPath = [System.IO.Path]::GetDirectoryName($YamlFilePath)
        $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($YamlFilePath)
        $extension = [System.IO.Path]::GetExtension($YamlFilePath)
        $outputFileName = $fileNameWithoutExtension + '.mt' + $extension
        return [System.IO.Path]::Combine($parentPath, $outputFileName)
    }
}

process {
    trap {
        $ex = $_.Exception
        $builder = New-Object -TypeName 'System.Text.StringBuilder'
        [void] $builder.AppendLine('')

        [void] $builder.AppendLine('**** EXCEPTION ****')
        [void] $builder.AppendLine($ex.Message)
        [void] $builder.AppendLine('')
        [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
        [void] $builder.AppendLine('FullyQualifiedErrorId: ' + $_.FullyQualifiedErrorId)
        [void] $builder.AppendLine('ErrorDetailsMessage: ' + $_.ErrorDetails.Message)
        [void] $builder.AppendLine('CategoryInfo: ' + $_.CategoryInfo.ToString())
        [void] $builder.AppendLine('PowerShell StackTrace:')
        [void] $builder.AppendLine($_.ScriptStackTrace)
        [void] $builder.AppendLine('')

        [void] $builder.AppendLine('--- Exception ---')
        [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
        [void] $builder.AppendLine('Message: ' + $ex.Message)
        [void] $builder.AppendLine('Source: ' + $ex.Source)
        [void] $builder.AppendLine('HResult: ' + $ex.HResult)
        [void] $builder.AppendLine('StackTrace:')
        [void] $builder.AppendLine($ex.StackTrace)

        $depth = 1
        while ($ex.InnerException) {
            $ex = $ex.InnerException
            [void] $builder.AppendLine('--- InnerException {0} ---' -f $depth)
            [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
            [void] $builder.AppendLine('Message: ' + $ex.Message)
            [void] $builder.AppendLine('Source: ' + $ex.Source)
            [void] $builder.AppendLine('HResult: ' + $ex.HResult)
            [void] $builder.AppendLine('StackTrace:')
            [void] $builder.AppendLine($ex.StackTrace)
            [void] $builder.AppendLine('---')
            $depth++
        }

        $message = $builder.ToString()
        Write-Host -Object $message -ForegroundColor Yellow
    }

    foreach ($yamlFilePath in $RecommendationYamlFilePath) {
        Write-Host ("Translate: ""{0}""" -f $yamlFilePath)
        $params = @{
            YamlFilePath  = $yamlFilePath
            TranslateFrom = $TranslateFrom
            TranslateTo   = $TranslateTo
            ApiKey        = $ApiKey
            Location      = $Location
            ApiEndpoint   = $ApiEndpoint
        }
        $translatedYaml = Invoke-RecommendationYamlTranslation @params

        $outputYamlFilePath = if ($Overwrite) {
            $yamlFilePath
        }
        else {
            New-OutputYamlFileName -YamlFilePath $yamlFilePath
        }
        $translatedYaml | Set-Content -Encoding UTF8 -LiteralPath $outputYamlFilePath -Force
        Write-Host ("Output   : ""{0}""" -f $outputYamlFilePath)
    }
}

end {}
