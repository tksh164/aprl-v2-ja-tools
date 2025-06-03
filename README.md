# aprl-v2-ja-tools

## recomm-yaml-translator.ps1

```powershell
$aprlFolderPath = 'J:\aprlv2\azure-resources'
$apiKey = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$location = 'japaneast'
$from = 'en'
$to = 'ja'

$filePaths = Get-ChildItem -File -Recurse -Filter '*.yaml' -LiteralPath $aprlFolderPath | Select-Object -ExpandProperty 'FullName'
$filePaths | .\recomm-yaml-translator.ps1 -TranslateFrom $from -TranslateTo $to -ApiKey $apiKey -Location $location -Overwrite
```

### Notes

- This script requires a [Translator resource](https://learn.microsoft.com/azure/ai-services/translator/text-translation/quickstart/rest-api) on Azure to run.
- Review the machine translation result before use it recommended because sometimes the machine translation result's quality is not good.
