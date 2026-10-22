<#
.SYNOPSIS
  Étape 1 - Crée les 3 environnements (dev, ppd, prd) du Hello World.
  Par environnement : 1 Resource Group, 1 Storage Account, 1 Function App
  (Flex Consumption, PowerShell) et 1 Static Web App (Free).

.NOTES
  Prérequis : Azure CLI, connecté avec `az login`.
  Ce script est relançable : si une ressource existe déjà, az la met à jour.
#>
param(
    [string]$SubscriptionId = "d8d3d385-4302-49f5-9309-5076f79ff46c",
    [string]$Location       = "westeurope",     # région du Resource Group, du stockage et de la Function App
    [string]$SwaLocation    = "westeurope",     # région de la Static Web App (contenu servi mondialement)
    [string]$Project        = "hello",
    [string[]]$Envs         = @("dev", "ppd", "prd")
)

$ErrorActionPreference = "Stop"
# Sans cette ligne, un échec de `az` (commande externe) n'arrête PAS le script
$PSNativeCommandUseErrorActionPreference = $true

# Suffixe aléatoire pour rendre les noms uniques au niveau mondial.
# On le mémorise dans un fichier pour que les relances réutilisent les mêmes noms.
$suffixFile = Join-Path $PSScriptRoot ".suffix"
if (Test-Path $suffixFile) {
    $suffix = (Get-Content $suffixFile).Trim()
} else {
    $suffix = -join ((97..122) + (48..57) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    Set-Content $suffixFile $suffix
}
Write-Host "Suffixe utilisé : $suffix" -ForegroundColor Cyan

az account set --subscription $SubscriptionId

$result = @{}
foreach ($env in $Envs) {
    $rg      = "rg-$Project-$env"
    $storage = "st$Project$env$suffix"          # 3-24 caractères, minuscules et chiffres uniquement
    $func    = "func-$Project-$env-$suffix"
    $swa     = "swa-$Project-$env-$suffix"
    $tags    = @("project=$Project", "env=$env", "owner=florian", "purpose=lab-cicd")

    Write-Host "`n=== Environnement $env ===" -ForegroundColor Yellow

    Write-Host "Resource Group $rg"
    az group create --name $rg --location $Location --tags @tags -o none

    Write-Host "Storage Account $storage"
    az storage account create --name $storage --resource-group $rg --location $Location `
        --sku Standard_LRS --allow-blob-public-access false --tags @tags -o none

    Write-Host "Function App $func (Flex Consumption, PowerShell 7.6)"
    az functionapp create --name $func --resource-group $rg --storage-account $storage `
        --flexconsumption-location $Location --runtime powershell --runtime-version 7.6 `
        --tags @tags -o none

    # Variable d'environnement lue par le code PowerShell pour savoir où il tourne
    az functionapp config appsettings set --name $func --resource-group $rg --settings "APP_ENV=$env" -o none

    Write-Host "Static Web App $swa (Free)"
    az staticwebapp create --name $swa --resource-group $rg --location $SwaLocation `
        --sku Free --tags @tags -o none

    $swaHost  = az staticwebapp show --name $swa --resource-group $rg --query defaultHostname -o tsv
    # On lit le nom d'hôte réel : les nouvelles apps peuvent avoir un nom d'hôte avec un hash et la région
    $funcHost = az functionapp show --name $func --resource-group $rg --query "defaultHostName || hostNames[0]" -o tsv
    if (-not $funcHost) { throw "Impossible de lire le nom d'hôte de $func" }

    # Le front (SWA) appelle l'API (Function) sur un autre domaine : il faut autoriser ce domaine (CORS).
    Write-Host "CORS : autorise https://$swaHost"
    az functionapp cors add --name $func --resource-group $rg --allowed-origins "https://$swaHost" -o none

    $result[$env] = [ordered]@{
        resourceGroup = $rg
        functionApp   = $func
        functionUrl   = "https://$funcHost"
        staticWebApp  = $swa
        frontUrl      = "https://$swaHost"
    }
}

$outFile = Join-Path $PSScriptRoot "envs.json"
$result | ConvertTo-Json -Depth 3 | Set-Content $outFile
Write-Host "`nTerminé. Récapitulatif écrit dans $outFile" -ForegroundColor Green
$result | ConvertTo-Json -Depth 3
