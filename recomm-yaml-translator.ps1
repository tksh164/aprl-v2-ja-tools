param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]] $RecommendationYamlFilePath,

    [Parameter(Mandatory = $true)]
    [string] $ApiKey,

    [Parameter(Mandatory = $true)]
    [string] $Location,

    [Parameter(Mandatory = $false)]
    [string] $ApiEndpoint = 'https://api.cognitive.microsofttranslator.com/',

    [Parameter(Mandatory = $false)]
    [switch] $Overwrite
)

begin
{
    function Test-RecommendationBlockStart
    {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)][AllowEmptyString()]
            [string] $Line
        )
    
        return $Line -match '^\-\s*description:.+$'
    }
    
    function Get-RecommendationBlockEndLineNum
    {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)][AllowEmptyString()]
            [string[]] $YamlLines,
    
            [Parameter(Mandatory = $true)]
            [int] $StartLineNum
        )
    
        $blockEndLineNum = -1
        for ($currentLineNum = $StartLineNum + 1; $currentLineNum -lt $YamlLines.Length; $currentLineNum++) {
            $currentLine = $YamlLines[$currentLineNum]
            if (Test-RecommendationBlockStart -Line $currentLine) {
                $blockEndLineNum = $currentLineNum
                break
            }
        }
    
        if ($blockEndLineNum -lt 0) {
            $blockEndLineNum = $YamlLines.Length
        }
    
        return $blockEndLineNum
    }
    
    function Get-TextToTranslate
    {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)][AllowEmptyString()]
            [string[]] $YamlLines,
    
            [Parameter(Mandatory = $true)]
            [int] $StartLineNum,
    
            [Parameter(Mandatory = $true)]
            [int] $EndLineNum
        )
    
        $result = [PSCustomObject] @{
            Description     = ''
            LongDescription = ''
        }
    
        $currentLineNum = $StartLineNum
        while ($currentLineNum -lt $EndLineNum) {
            $currentLine = $YamlLines[$currentLineNum]
    
            # description
            if ($currentLine -match '^\-\s*description:\s*(.+)$') {
                $result.Description = $Matches[1]
                $currentLineNum++
            }
            # longDescription
            elseif ($currentLine -match '^\s+longDescription:\s*\|\s*$') {
                $nextLine = $YamlLines[$currentLineNum + 1]
                if ($nextLine -match '^\s+(.+)$') {
                    $result.LongDescription = $Matches[1]
                    $currentLineNum = $currentLineNum + 2
                }
                else {
                    throw 'Unexpected mismatch on "longDescription". The line was "{0}".' -f $nextLine
                }
            }
            else {
                $currentLineNum++
            }
        }
    
        return $result
    }
    
    function Invoke-Translation
    {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [PSCustomObject] $TextToTranslate,

            [Parameter(Mandatory = $true)]
            [string] $ApiKey,
        
            [Parameter(Mandatory = $true)]
            [string] $Location,
        
            [Parameter(Mandatory = $true)]
            [string] $ApiEndpoint
        )
    
        $from = 'en'
        $to = 'ja'
        $params = @{
            Method  = 'Post'
            Uri     = '{0}/translate?api-version=3.0&from={1}&to={2}' -f $ApiEndpoint, $from, $to
            Headers = @{
                'Content-Type'                 = 'application/json'
                'Ocp-Apim-Subscription-Key'    = $ApiKey
                'Ocp-Apim-Subscription-Region' = $Location
            }
            Body = ,@(
                @{ 'Text' = $TextToTranslate.Description }
                @{ 'Text' = $TextToTranslate.LongDescription }
            ) | ConvertTo-Json
        }

        $maxRetryCount = 3
        for ($retried = 0; $retried -lt $maxRetryCount; $retried++) {
            try {
                $result = Invoke-RestMethod @params
            }
            catch {
                if (($_.Exception -is [System.Net.Http.HttpRequestException]) -and ($_.Exception.Message -like '*established connection failed*')) {
                    $waitSeconds = 15
                    Write-Host -Object ('Failed the translator API call. Will retrying after waiting {0} seconds...' -f $waitSeconds) -ForegroundColor Yellow
                    Start-Sleep -Seconds $waitSeconds
                }
                else {
                    throw $_
                }
            }
        }

        return [PSCustomObject] @{
            Description     = $result.translations[0].text
            LongDescription = $result.translations[1].text
        }
    }
    
    function New-TranslatedRecommendationBlock
    {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)][AllowEmptyString()]
            [string[]] $YamlLines,
    
            [Parameter(Mandatory = $true)]
            [int] $StartLineNum,
    
            [Parameter(Mandatory = $true)]
            [int] $EndLineNum,
    
            [Parameter(Mandatory = $true)]
            [PSCustomObject] $TranslatedText
        )
        
        $yamlBlockBuilder = New-Object -TypeName 'System.Text.StringBuilder'
        $currentLineNum = $StartLineNum
        while ($currentLineNum -lt $EndLineNum) {
            $currentLine = $YamlLines[$currentLineNum]
    
            # description
            if ($currentLine -match '^(\-\s*description:\s*).+$') {
                [void] $yamlBlockBuilder.AppendLine($Matches[1] + $TranslatedText.Description)
                $currentLineNum++
            }
            # longDescription
            elseif ($currentLine -match '^\s+longDescription:\s*\|\s*$') {
                $nextLine = $YamlLines[$currentLineNum + 1]
                if ($nextLine -match '^(\s+).+$') {
                    [void] $yamlBlockBuilder.AppendLine($currentLine)
                    [void] $yamlBlockBuilder.AppendLine($Matches[1] + $TranslatedText.LongDescription)
                    $currentLineNum = $currentLineNum + 2
                }
                else {
                    throw 'Unexpected mismatch on "longDescription". The line was "{0}".' -f $nextLine
                }
            }
            # learnMoreLink.url
            elseif ($currentLine -match '^(\s+url:\s*)(.+)$') {
                $headPart = $Matches[1]
                $urlPart = $Matches[2].Replace('/en-us/', '/ja-jp/')
                [void] $yamlBlockBuilder.AppendLine($headPart + $urlPart)
                $currentLineNum++
            }
            # other lines
            else {
                [void] $yamlBlockBuilder.AppendLine($currentLine)
                $currentLineNum++
            }
        }
        return $yamlBlockBuilder.ToString()
    }

    function New-OutputYamlFileName
    {
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

    function New-ExceptionMessage
    {
        param (
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.ErrorRecord] $ErrorRecord
        )

        $ex = $_.Exception
        $builder = New-Object -TypeName 'System.Text.StringBuilder'
        [void] $builder.AppendLine('')

        [void] $builder.AppendLine('>>> EXCEPTION <<<')
        [void] $builder.AppendLine($ex.Message)
        [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
        [void] $builder.AppendLine('FullyQualifiedErrorId: ' + $_.FullyQualifiedErrorId)
        [void] $builder.AppendLine('ErrorDetailsMessage: ' + $_.ErrorDetails.Message)
        [void] $builder.AppendLine('CategoryInfo: ' + $_.CategoryInfo.ToString())
        [void] $builder.AppendLine('StackTrace in PowerShell:')
        [void] $builder.AppendLine($_.ScriptStackTrace)

        [void] $builder.AppendLine('--- Exception ---')
        [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
        [void] $builder.AppendLine('Message: ' + $ex.Message)
        [void] $builder.AppendLine('Source: ' + $ex.Source)
        [void] $builder.AppendLine('HResult: ' + $ex.HResult)
        [void] $builder.AppendLine('StackTrace:')
        [void] $builder.AppendLine($ex.StackTrace)

        $level = 1
        while ($ex.InnerException) {
            $ex = $ex.InnerException
            [void] $builder.AppendLine('--- InnerException {0} ---' -f $level)
            [void] $builder.AppendLine('Exception: ' + $ex.GetType().FullName)
            [void] $builder.AppendLine('Message: ' + $ex.Message)
            [void] $builder.AppendLine('Source: ' + $ex.Source)
            [void] $builder.AppendLine('HResult: ' + $ex.HResult)
            [void] $builder.AppendLine('StackTrace:')
            [void] $builder.AppendLine($ex.StackTrace)
            [void] $builder.AppendLine('---')
            $level++
        }

        return $builder.ToString()
    }
}

process
{
    foreach ($yamlFilePath in $RecommendationYamlFilePath) {
        try {
            Write-Host ("Translate:`t""{0}""" -f $yamlFilePath)
            $resultYamlBuilder = New-Object -TypeName 'System.Text.StringBuilder'
    
            $yamlLines = Get-Content -Encoding UTF8 -LiteralPath $yamlFilePath
            $currentLineNum = 0
            while ($currentLineNum -lt $yamlLines.Length) {
                $currentLine = $yamlLines[$currentLineNum]
                if (Test-RecommendationBlockStart -Line $currentLine) {
                    $currentBlockEndLineNum = Get-RecommendationBlockEndLineNum -YamlLines $yamlLines -StartLineNum $currentLineNum
                    $textToTranslate = Get-TextToTranslate -YamlLines $yamlLines -StartLineNum $currentLineNum -EndLineNum $currentBlockEndLineNum
                    $translatedText = Invoke-Translation -TextToTranslate $textToTranslate -ApiKey $ApiKey -Location $Location -ApiEndpoint $ApiEndpoint
                    $translatedBlock = New-TranslatedRecommendationBlock -YamlLines $yamlLines -StartLineNum $currentLineNum -EndLineNum $currentBlockEndLineNum -TranslatedText $translatedText
                    [void] $resultYamlBuilder.Append($translatedBlock)
                    $currentLineNum = $currentBlockEndLineNum
                }
                else {
                    $currentLineNum++
                }
            }
    
            if ($Overwrite) {
                $outputYamlFilePath = $yamlFilePath
            }
            else {
                $outputYamlFilePath = New-OutputYamlFileName -YamlFilePath $yamlFilePath
            }
            $resultYamlBuilder.ToString().TrimEnd() | Set-Content -Encoding UTF8 -LiteralPath $outputYamlFilePath -Force
            Write-Host ("Output:`t`t""{0}""" -f $outputYamlFilePath)
        }
        catch {
            throw New-ExceptionMessage -ErrorRecord $_
        }
    }
}

end
{
}
