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
  ./setup-github-oidc.ps1 -GitHubRepo "furokun78@9333766/hello-azure-cicd@1429868264"

.NOTES
  GitHub peut présenter le repo sous deux formes dans le jeton OIDC :
    - classique  : owner/repo
    - immuable   : owner@ownerId/repo@repoId  (c'est le cas de ce repo)
  En cas d'erreur AADSTS700213, reprendre exactement la forme affichée dans le message d'erreur.
#>
param(
    [Parameter(Mandatory)] [string]$GitHubRepo,   # tel qu'il apparaît dans le "subject" du jeton GitHub
    [string]$SubscriptionId = "d8d3d385-4302-49f5-9309-5076f79ff46c",
    [string]$Project        = "hello",
    [string[]]$Envs         = @("dev", "ppd", "prd")
)

$ErrorActionPreference = "Stop"
# Sans cette ligne, un échec de `az` (commande externe) n'arrête PAS le script
$PSNativeCommandUseErrorActionPreference = $true
az account set --subscription $SubscriptionId
$tenantId = az account show --query tenantId -o tsv

$summary = @()
foreach ($env in $Envs) {
    $appName = "gh-$Project-$env"
    $rg      = "rg-$Project-$env"

    # On lit les noms directement dans Azure : aucun fichier local n'est nécessaire
    $func     = az resource list -g $rg --resource-type Microsoft.Web/sites --query "[0].name" -o tsv
    $swa      = az resource list -g $rg --resource-type Microsoft.Web/staticSites --query "[0].name" -o tsv
    if (-not $func -or -not $swa) { throw "Function App ou Static Web App introuvable dans $rg : lance d'abord setup-envs.ps1" }
    $funcHost = az resource show -g $rg -n $func --resource-type Microsoft.Web/sites --query properties.defaultHostName -o tsv
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
    $subject  = "repo:${GitHubRepo}:environment:$env"
    $existing = az ad app federated-credential list --id $appId --query "[?name=='$credName'].subject" -o tsv
    if ($existing -ne $subject) {
        $tmp = New-TemporaryFile
        @{
            name      = $credName
            issuer    = "https://token.actions.githubusercontent.com"
            subject   = $subject
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json | Set-Content $tmp
        if ($existing) {
            # Le sujet a changé (ex : format immuable) : on met à jour la credential existante
            az ad app federated-credential update --id $appId --federated-credential-id $credName --parameters "@$tmp" -o none
        } else {
            az ad app federated-credential create --id $appId --parameters "@$tmp" -o none
        }
        Remove-Item $tmp
        Write-Host "Federated credential : $subject"
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
        FUNCTION_APP    = $func
        STATIC_WEB_APP  = $swa
        API_URL         = "https://$funcHost"
    }
}

Write-Host "`nValeurs communes (variables du repo GitHub) :" -ForegroundColor Green
Write-Host "  AZURE_TENANT_ID       = $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SubscriptionId"
Write-Host "`nValeurs par GitHub Environment :" -ForegroundColor Green
$summary | Format-List
$summary | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot "github-vars.json")
