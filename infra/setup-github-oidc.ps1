<#
.SYNOPSIS
  Étape 3 - Autorise GitHub Actions à déployer dans Azure, sans aucun mot de passe (OIDC).

.DESCRIPTION
  Pour chaque environnement (dev, ppd, prd), le script crée :
    1. une App Registration Entra ID "gh-hello-<env>" et son Service Principal ;
    2. une "federated credential" : Entra fera confiance aux jetons émis par GitHub,
       UNIQUEMENT pour ce repo ET ce GitHub Environment (ex : repo:owner/repo:environment:prd) ;
    3. le rôle Contributor sur LE SEUL Resource Group de cet environnement.

  Résultat : un job GitHub qui tourne dans l'environnement "dev" ne peut pas toucher à la prod.

.EXAMPLE
  ./setup-github-oidc.ps1 -GitHubRepo "monCompte/hello-azure-cicd"
#>
param(
    [Parameter(Mandatory)] [string]$GitHubRepo,   # format owner/repo
    [string]$SubscriptionId = "d8d3d385-4302-49f5-9309-5076f79ff46c",
    [string]$Project        = "hello",
    [string[]]$Envs         = @("dev", "ppd", "prd")
)

$ErrorActionPreference = "Stop"
# Sans cette ligne, un échec de `az` (commande externe) n'arrête PAS le script
$PSNativeCommandUseErrorActionPreference = $true
az account set --subscription $SubscriptionId
$tenantId = az account show --query tenantId -o tsv

$envsFile = Join-Path $PSScriptRoot "envs.json"
if (-not (Test-Path $envsFile)) { throw "envs.json introuvable : lance d'abord setup-envs.ps1" }
$envs = Get-Content $envsFile | ConvertFrom-Json

$summary = @()
foreach ($env in $Envs) {
    $appName = "gh-$Project-$env"
    $rg      = $envs.$env.resourceGroup
    Write-Host "`n=== $env : $appName -> $rg ===" -ForegroundColor Yellow

    # 1. App Registration + Service Principal (réutilise l'existante si le script est relancé)
    $appId = az ad app list --display-name $appName --query "[0].appId" -o tsv
    if (-not $appId) {
        $appId = az ad app create --display-name $appName --query appId -o tsv
        Write-Host "App Registration créée : $appId"
    }
    $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
    if (-not $spId) {
        $spId = az ad sp create --id $appId --query id -o tsv
    }

    # 2. Federated credential : confiance limitée à ce repo + ce GitHub Environment
    $credName = "github-$env"
    $existing = az ad app federated-credential list --id $appId --query "[?name=='$credName'].name" -o tsv
    if (-not $existing) {
        $tmp = New-TemporaryFile
        @{
            name      = $credName
            issuer    = "https://token.actions.githubusercontent.com"
            subject   = "repo:${GitHubRepo}:environment:$env"
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json | Set-Content $tmp
        az ad app federated-credential create --id $appId --parameters "@$tmp" -o none
        Remove-Item $tmp
        Write-Host "Federated credential : repo:${GitHubRepo}:environment:$env"
    }

    # 3. Droits limités au Resource Group de l'environnement
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
    az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
        --role Contributor --scope $scope -o none
    Write-Host "Rôle Contributor sur $rg"

    $summary += [pscustomobject]@{
        Environment     = $env
        AZURE_CLIENT_ID = $appId
        RESOURCE_GROUP  = $rg
        FUNCTION_APP    = $envs.$env.functionApp
        STATIC_WEB_APP  = $envs.$env.staticWebApp
        API_URL         = $envs.$env.functionUrl
    }
}

Write-Host "`nValeurs communes (variables du repo GitHub) :" -ForegroundColor Green
Write-Host "  AZURE_TENANT_ID       = $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SubscriptionId"
Write-Host "`nValeurs par GitHub Environment :" -ForegroundColor Green
$summary | Format-List
$summary | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot "github-vars.json")
