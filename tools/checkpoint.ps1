param([Parameter(Mandatory=$true)][string]$Message, [switch]$Push)
$ErrorActionPreference='Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
# Explicit source roots; ignore rules keep credentials and local data out.
$roots=@('.github','.gitignore','.metadata','.zcodeignore','PROJECT_STRUCTURE.md','README.md','analysis_options.yaml','devtools_options.yaml','android','ios','assets','lib','test','docs','tools','pubspec.yaml','pubspec.lock','build_android.ps1') | Where-Object {Test-Path -LiteralPath $_}
& git add -- @roots
if ($LASTEXITCODE -ne 0) { throw 'Git add failed' }
& python tools/verify_publishable_sources.py
if ($LASTEXITCODE -ne 0) { throw 'Potential secret found. Nothing committed or pushed.' }
& git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
  & git commit -m $Message
  if ($LASTEXITCODE -ne 0) { throw 'Commit failed' }
}
if ($Push) {
  & git push -u origin HEAD
  if ($LASTEXITCODE -ne 0) { throw 'Push failed; local commit remains available' }
}
