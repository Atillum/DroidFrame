$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$output = Join-Path $root 'dist/DroidFrame-Windows-x64'
New-Item -ItemType Directory -Force "$output/deps/scrcpy" | Out-Null
$zip = Join-Path $env:RUNNER_TEMP 'scrcpy-win64-v5.0.1.zip'
Invoke-WebRequest 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-win64-v5.0.1.zip' -OutFile $zip
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'b12a2c4ee8be317422451fc7dcf8ee20a71b5ea7ef9ad73ddd825a25316227a5') { throw 'scrcpy checksum mismatch' }
$unpack = Join-Path $env:RUNNER_TEMP 'scrcpy-unpacked'
Expand-Archive $zip $unpack -Force
Copy-Item "$unpack/scrcpy-win64-v5.0.1/*" "$output/deps/scrcpy/" -Recurse -Force
dotnet publish "$root/windows/DroidFrame.csproj" -c Release -r win-x64 --self-contained true -o $output
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
Copy-Item -Path "$root/LICENSE","$root/THIRD-PARTY.md","$root/README.md" -Destination $output
Copy-Item -Path "$root/licenses" -Destination $output -Recurse -Force
# app-local native/runtime files are kept together for fast startup, without extraction.
