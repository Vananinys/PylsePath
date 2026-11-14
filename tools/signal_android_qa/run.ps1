param(
  [Parameter(Mandatory=$true)][string]$DeviceId,
  [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'pulsepath-signal-stage-qa')
)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$taskPubspec = Join-Path $WorkDirectory 'pubspec.yaml'
if (Test-Path -LiteralPath $taskPubspec) {
  if ((Get-Content -LiteralPath $taskPubspec -Raw) -notmatch '(?m)^name: signal_device_check\s*$') {
    throw 'WorkDirectory contains another project; choose a separate QA directory.'
  }
} else {
  & flutter create --platforms=android --org=com.pulsepath.signalqa --project-name=signal_device_check $WorkDirectory
  if ($LASTEXITCODE -ne 0) { throw 'QA project creation failed' }
}
$taskYaml = @('name: signal_device_check', 'publish_to: none', 'version: 1.0.0+1', 'environment:', "  sdk: '>=3.13.0 <4.0.0'", 'dependencies:', '  flutter:', '    sdk: flutter', '  libsignal: 9.0.0', '  sqflite: 2.4.4', '  flutter_secure_storage: 10.3.4', '  cryptography: 2.9.0', '  crypto: 3.0.7', 'dev_dependencies:', '  flutter_test:', '    sdk: flutter', '  integration_test:', '    sdk: flutter', 'flutter:', '  uses-material-design: true')
$taskYaml | Set-Content -LiteralPath $taskPubspec -Encoding utf8
$taskSources = @('lib/data/signal_protocol_stores.dart', 'lib/data/signal_state_database.dart', 'lib/data/signal_isolate_mutex.dart', 'lib/data/e2ee_recovery_vault.dart', 'lib/services/signal_message_engine.dart')
foreach ($taskSource in $taskSources) {
  $taskTarget = Join-Path $WorkDirectory $taskSource
  New-Item -ItemType Directory -Force -Path (Split-Path $taskTarget -Parent) | Out-Null
  Copy-Item -LiteralPath (Join-Path $taskRepo $taskSource) -Destination $taskTarget
}
New-Item -ItemType Directory -Force -Path (Join-Path $WorkDirectory 'integration_test') | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'integration_test/signal_engine_test.dart') -Destination (Join-Path $WorkDirectory 'integration_test/signal_engine_test.dart')
Push-Location $WorkDirectory
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'QA dependency resolution failed' }
  & flutter test integration_test/signal_engine_test.dart -d $DeviceId --no-uninstall --reporter expanded
  if ($LASTEXITCODE -ne 0) { throw 'Signal Android QA failed' }
} finally { Pop-Location }
