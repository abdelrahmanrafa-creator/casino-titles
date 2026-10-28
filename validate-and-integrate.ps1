param([switch]$SkipTests,[switch]$NoBuild)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
function Invoke-Checked([string]$Label,[scriptblock]$Action) {
 Write-Host "`n--- $Label ---" -ForegroundColor Cyan
 & $Action
 if ($LASTEXITCODE -ne 0) {throw "$Label a échoué (code $LASTEXITCODE). Intégration arrêtée."}
}
try {
 foreach ($file in @('package.json','src/features/pool3d/materials.ts','src/features/pool3d/scene.ts','src/lib/poolAim.ts','src/lib/poolCamera.ts','src/features/PoolPower.tsx','src/features/PoolSpin.tsx')) {
  if (-not (Test-Path -LiteralPath $file)) {throw "Fichier manquant : $file"}
 }
 if (-not (Test-Path -LiteralPath node_modules)) {Invoke-Checked 'Installation npm' {npm ci}}
 Invoke-Checked 'Traductions' {npm run i18n:build}
 Invoke-Checked 'Couverture français et anglais' {npm run i18n:check}
 Invoke-Checked 'TypeScript' {npx --no-install tsc --noEmit}
 if ($SkipTests) {Write-Warning 'Tests ignorés : la validation est partielle.'} else {Invoke-Checked 'Tests automatisés' {npm test}}
 if ($NoBuild) {Write-Warning 'Build ignoré : la validation est partielle.'} else {Invoke-Checked 'Build de production' {npm run build}}
 Invoke-Checked 'État Git' {git status --short}
 if ($SkipTests -or $NoBuild) {Write-Host 'Contrôles demandés terminés. Validation complète non effectuée.' -ForegroundColor Yellow}
 else {Write-Host 'Validation complète réussie. Aucun commit, push ou déploiement effectué par ce script.' -ForegroundColor Green}
} catch {Write-Error -Message $_ -ErrorAction Continue;exit 1}
