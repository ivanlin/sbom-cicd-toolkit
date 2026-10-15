# Native installer for Windows (PowerShell). Downloads the SAME pinned versions as the
# container (tools.lock: syft grype trivy yq jq cosign), verifies the asset sha256 and the
# installed-executable sha256 (*_BIN_SHA256_windows_amd64), and copies sbomgate, sbomsign and
# trusted-keys.yaml. sbomgate / sbomsign are bash scripts and run
# under Git Bash (ships with Git for Windows):  & "C:\Program Files\Git\bin\bash.exe" -lc "sbomgate tools"
param([string]$Prefix = "$env:USERPROFILE\.sbom-cicd-toolkit")
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$lock = @{}
Get-Content "$Here\tools.lock" | Where-Object { $_ -match '^[A-Z_0-9a-z]+=' } | ForEach-Object { $k,$v = $_ -split '=',2; $lock[$k] = $v }
$Bin = Join-Path $Prefix "bin"; New-Item -ItemType Directory -Force -Path $Bin | Out-Null
$Tmp = Join-Path $env:TEMP ("sbomgate-" + [guid]::NewGuid()); New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
function Get-Verified($url, $dest, $sha) {
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  $got = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLower()
  if ($got -ne $sha) { throw "sha256 mismatch for ${dest}: got $got want $sha" }
}
Get-Verified "https://github.com/anchore/syft/releases/download/v$($lock.SYFT_VERSION)/syft_$($lock.SYFT_VERSION)_windows_amd64.zip" "$Tmp\syft.zip" $lock.SYFT_SHA256_windows_amd64
Get-Verified "https://github.com/anchore/grype/releases/download/v$($lock.GRYPE_VERSION)/grype_$($lock.GRYPE_VERSION)_windows_amd64.zip" "$Tmp\grype.zip" $lock.GRYPE_SHA256_windows_amd64
Get-Verified "https://github.com/aquasecurity/trivy/releases/download/v$($lock.TRIVY_VERSION)/trivy_$($lock.TRIVY_VERSION)_windows-64bit.zip" "$Tmp\trivy.zip" $lock.TRIVY_SHA256_windows_amd64
Get-Verified "https://github.com/mikefarah/yq/releases/download/v$($lock.YQ_VERSION)/yq_windows_amd64.exe" "$Bin\yq.exe" $lock.YQ_SHA256_windows_amd64
Get-Verified "https://github.com/jqlang/jq/releases/download/jq-$($lock.JQ_VERSION)/jq-windows-amd64.exe" "$Bin\jq.exe" $lock.JQ_SHA256_windows_amd64
Get-Verified "https://github.com/sigstore/cosign/releases/download/v$($lock.COSIGN_VERSION)/cosign-windows-amd64.exe" "$Bin\cosign.exe" $lock.COSIGN_SHA256_windows_amd64
foreach ($t in "syft","grype","trivy") { Expand-Archive -Force "$Tmp\$t.zip" "$Tmp\$t"; Copy-Item "$Tmp\$t\$t.exe" "$Bin\$t.exe" -Force }
foreach ($t in "syft","grype","trivy","yq","jq","cosign") {
  $want = $lock["$($t.ToUpper())_BIN_SHA256_windows_amd64"]
  if (-not $want) { throw "$($t.ToUpper())_BIN_SHA256_windows_amd64 missing in tools.lock" }
  $got = (Get-FileHash -Algorithm SHA256 "$Bin\$t.exe").Hash.ToLower()
  if ($got -ne $want) { throw "installed $t.exe sha256 $got does not match tools.lock $want" }
}
Copy-Item "$Here\bin\sbomgate" "$Bin\sbomgate" -Force
Copy-Item "$Here\bin\sbomsign" "$Bin\sbomsign" -Force
Copy-Item "$Here\VERSION","$Here\tools.lock" $Prefix -Force
Copy-Item "$Here\policy\trusted-keys.yaml" "$Prefix\trusted-keys.yaml" -Force
Remove-Item -Recurse -Force $Tmp
Write-Host "installed into $Bin : $((Get-ChildItem $Bin).Name -join ' ')"
Write-Host "run under Git Bash:  PATH=`"$($Bin -replace '\\','/'):`$PATH`" SBOMGATE_HOME=`"$($Prefix -replace '\\','/')`" sbomgate tools"
