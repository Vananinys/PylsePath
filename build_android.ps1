# PulsePath Android build script (replaces the lost run_android.ps1 build flow).
#
# Why this exists: the project folder path contains Cyrillic characters, which
# breaks Gradle/AAPT. The proven workaround is to build from the ASCII working
# copy C:\src\pulsepath-build: sync sources there, build, copy the APK back.
#
# Usage (from the project folder):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build_android.ps1              # release build
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build_android.ps1 -DebugBuild  # debug build
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build_android.ps1 -Install     # build + adb install
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build_android.ps1 -Offline     # no-network build
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build_android.ps1 -Clean       # wipe app intermediates first
#
# NOTE for maintainers: keep this file pure ASCII. PowerShell 5.1 reads
# scripts without a BOM using the ANSI codepage, so any Cyrillic text here
# would turn into mojibake and break parsing.

param(
  [switch]$DebugBuild,
  [switch]$Clean,
  [switch]$Offline,
  [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Project  = $PSScriptRoot
$BuildRoot = 'C:\src\pulsepath-build'
$Flutter  = 'C:\src\flutter\bin\flutter.bat'
$Adb      = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$Mode     = if ($DebugBuild) { 'debug' } else { 'release' }

function Fail([string]$msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if (-not (Test-Path (Join-Path $Project 'pubspec.yaml'))) { Fail "pubspec.yaml not found next to the script ($Project)" }
if (-not (Test-Path $BuildRoot)) { Fail "build root missing: $BuildRoot" }
if (-not (Test-Path $Flutter))   { Fail "flutter not found: $Flutter" }

# --- 1) Sync sources into the ASCII build copy -------------------------------
# /MIR mirrors the trees; excluded dirs (build outputs, gradle caches) are
# preserved on the destination and never deleted.
Step 'Syncing sources into the ASCII build copy'
$mirrors = @(
  @{ Src = "$Project\lib";    Dst = "$BuildRoot\lib";    ExcludeDirs = @() },
  @{ Src = "$Project\test";   Dst = "$BuildRoot\test";   ExcludeDirs = @() },
  @{ Src = "$Project\assets"; Dst = "$BuildRoot\assets"; ExcludeDirs = @() },
  @{ Src = "$Project\ios";    Dst = "$BuildRoot\ios";    ExcludeDirs = @() },
  @{ Src = "$Project\android"; Dst = "$BuildRoot\android"; ExcludeDirs = @('build', '.gradle', '.cxx') }
)
foreach ($m in $mirrors) {
  $rcArgs = @($m.Src, $m.Dst, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  foreach ($x in $m.ExcludeDirs) { $rcArgs += @('/XD', $x) }
  & robocopy @rcArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { Fail "robocopy failed for $($m.Src) (code $LASTEXITCODE)" }
}
foreach ($f in @('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml')) {
  Copy-Item -LiteralPath (Join-Path $Project $f) -Destination (Join-Path $BuildRoot $f) -Force
}

# --- 2) Optional clean (never touches the offline Maven mirror) --------------
if ($Clean) {
  Step 'Cleaning previous app intermediates'
  foreach ($p in @("$BuildRoot\build\app", "$BuildRoot\.dart_tool\flutter_build")) {
    if (Test-Path $p) { & cmd /c "rd /s /q `"$p`"" ; if (Test-Path $p) { Fail "cannot remove $p" } }
  }
}

# --- 3) Offline wiring --------------------------------------------------------
# settings.gradle.kts flips Gradle to offline mode when the pulsepath.offline
# gradle property is set; the recorded local Maven mirror is injected as the
# first repository so plugin/dependency resolution works without DNS.
if ($Offline) {
  Step 'Enabling offline mode (recorded Maven mirror + Gradle offline)'
  Add-Content -Path "$BuildRoot\android\gradle.properties" -Value "`npulsepath.offline=true"
  $mavenUrl = 'file:///C:/src/pulsepath-build/build/test_dependencies/recording-maven'
  if (Test-Path "$BuildRoot\build\test_dependencies\recording-maven") {
    $settingsPath = "$BuildRoot\android\settings.gradle.kts"
    $txt = [IO.File]::ReadAllText($settingsPath)
    if ($txt -notmatch [regex]::Escape('recording-maven')) {
      $txt = $txt.Replace('    repositories {', "    repositories {`r`n        maven { url = uri(`"$mavenUrl`") }")
      [IO.File]::WriteAllText($settingsPath, $txt)
    }
  } else {
    Write-Host 'WARN: recording-maven mirror not found, offline build may fail' -ForegroundColor Yellow
  }
}

# --- 4) pub get ---------------------------------------------------------------
Step 'Resolving Dart packages'
$pubArgs = @('pub', 'get')
if ($Offline) { $pubArgs += '--offline' }
Push-Location $BuildRoot
try {
  & $Flutter @pubArgs
  if ($LASTEXITCODE -ne 0) { Fail "flutter pub get failed (code $LASTEXITCODE)" }

  # --- 5) Build the APK --------------------------------------------------------
  Step "Building $Mode APK (this can take a few minutes)"
  & $Flutter build apk "--$Mode"
  if ($LASTEXITCODE -ne 0) { Fail "flutter build apk failed (code $LASTEXITCODE)" }
} finally {
  Pop-Location
}

# --- 6) Copy the APK back into the project ------------------------------------
$builtApk = "$BuildRoot\build\app\outputs\flutter-apk\app-$Mode.apk"
if (-not (Test-Path $builtApk)) { Fail "APK not found after build: $builtApk" }
$outDir = "$Project\build\app\outputs\flutter-apk"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Copy-Item -LiteralPath $builtApk -Destination $outDir -Force
$outApk = "$outDir\app-$Mode.apk"
$size = [math]::Round((Get-Item -LiteralPath $outApk).Length / 1MB, 1)
Step "APK ready: $outApk ($size MB)"

# --- 7) Optional install -------------------------------------------------------
if ($Install) {
  if (-not (Test-Path $Adb)) { Fail "adb not found: $Adb" }
  Step 'Installing to the connected device'
  & $Adb install -r $outApk
  if ($LASTEXITCODE -ne 0) { Fail "adb install failed (code $LASTEXITCODE)" }
  Step 'Installed'
}
