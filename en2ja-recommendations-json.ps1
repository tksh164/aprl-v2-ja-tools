param (
    [Parameter(Mandatory = $true)]
    [string] $RecommendationsJsonFilePath,

    [Parameter(Mandatory = $true)]
    [string[]] $YamlFolderPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputFilePath
)

Import-Module -Name 'powershell-yaml' -Force

function New-AprlGuidToRecommendationHash {
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $TargetFolderPath
    )
    
    $hashByAprlGuid = @{}
    $TargetFolderPath | Get-ChildItem -Filter '*.yaml' -Recurse | ForEach-Object -Process {
        $yamlFile = $_

        # Get recommendations from a yaml file.
        (Get-Content -LiteralPath $yamlFile.FullName -Raw | ConvertFrom-Yaml) | Select-Object -Property @(
            'aprlGuid',
            'recommendationTypeId',
            'recommendationMetadataState',
            'learnMoreLink',
            'recommendationControl',
            'longDescription',
            'pgVerified',
            'description',
            'potentialBenefits',
            'tags',
            'recommendationResourceType',
            'recommendationImpact',
            'automationAvailable'
        ) | ForEach-Object -Process {
            $hashByAprlGuid[$_.aprlGuid] = $_
        }
    }

    return $hashByAprlGuid
}

function Get-ReplacedRecommendationWithHash {
    param (
        [Parameter(Mandatory = $true)]
        [string] $RecommendationsJsonFilePath,

        [Parameter(Mandatory = $true)]
        [hashtable] $AprlGuidToRecommendationHash
    )

    Get-Content -LiteralPath $RecommendationsJsonFilePath -Raw | ConvertFrom-Json | ForEach-Object -Process {
        $recommendationInJson = $_  # A recommendation from the recommendations.json file.
        $recommendationInHash = $AprlGuidToRecommendationHash[$recommendationInJson.aprlGuid]  # A recommendation from the APRL YAML files.
    
        # Replace the properties of the recommendation in the recommendations.json file with the properties of the recommendation in the APRL YAML files.
        # This means that replace English to Japanese.
        $recommendationInJson.longDescription = $recommendationInHash.longDescription
        $recommendationInJson.description = $recommendationInHash.description
        if ($recommendationInHash.learnMoreLink -ne $null) {
            $recommendationInJson.learnMoreLink[0].url = $recommendationInHash.learnMoreLink[0].url
            $recommendationInJson.learnMoreLink[0].name = $recommendationInHash.learnMoreLink[0].name
        }
        else {
            Write-Host ('{0} is not in the recommendation hash.' -f $recommendationInJson.aprlGuid)
        }
        $recommendationInJson
    }
}

# Create a hash table from the APRL recommendation YAML files. The hash maps an APRL GUID to a recommendation object.
$aprlGuidToRecommendationHash = New-AprlGuidToRecommendationHash -TargetFolderPath $YamlFolderPath

# Get replaced recommendations.json content with the APRL recommendation YAML files. This means that replace English to Japanese.
Get-ReplacedRecommendationWithHash -RecommendationsJsonFilePath $recommendationsJsonFilePath -AprlGuidToRecommendationHash $aprlGuidToRecommendationHash | ConvertTo-Json -Depth 20 | Out-File -FilePath $OutputFilePath -Force
