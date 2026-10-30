using namespace System.Net

# Appelé à chaque requête HTTP GET sur /api/hello
param($Request, $TriggerMetadata)

$name = $Request.Query.name
if (-not $name) { $name = "World" }

# [ordered] garantit l'ordre des clés dans le JSON (une table @{} simple ne le garantit pas)
$body = [ordered]@{
    message     = "Hello $name !"
    environment = $env:APP_ENV          # défini par setup-envs.ps1 : dev, ppd ou prd
    psVersion   = $PSVersionTable.PSVersion.ToString()
    timestamp   = (Get-Date).ToUniversalTime().ToString("o")
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers    = @{ "Content-Type" = "application/json" }
    Body       = $body
})
