# Public QA only, approved for the exact public release repository and fresh hosted VM.
# Requires a fresh GitHub-hosted Windows VM; never run on a user's computer.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Installer,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$InstallerSha256,
  [ValidatePattern('^\d+\.\d+\.\d+$')][string]$FromVersion = '0.1.59',
  [ValidatePattern('^\d+\.\d+\.\d+$')][string]$ToVersion = '0.1.63'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'sbbik/saminbun-desktop-releases') {
  throw 'FRESH_APPROVED_PUBLIC_WINDOWS_RUNNER_REQUIRED'
}
if ($env:SAMINBUN_DESKTOP_QA_USER_DATA) { throw 'QA_REQUIRES_DEFAULT_PROFILE' }
if ($FromVersion -eq $ToVersion) { throw 'QA_REQUIRES_DISTINCT_VERSIONS' }
$Installer = (Resolve-Path -LiteralPath $Installer).Path
if ((Split-Path $Installer -Leaf) -ne "saminbun-setup-$FromVersion-x64.exe") { throw 'INSTALLER_NAME_MISMATCH' }
if ((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash -ne $InstallerSha256) { throw 'INSTALLER_HASH_MISMATCH' }
$Node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
if (-not ($Node -is [string]) -or -not (Test-Path -LiteralPath $Node -PathType Leaf)) { throw 'EXACT_NODE_EXECUTABLE_REQUIRED' }
$Helper = Join-Path $PSScriptRoot 'windows-update-smoke.mjs'
if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) { throw 'QA_HELPER_MISSING' }
$Guid = 'd24e5421-91c4-5ae4-ae45-da0dd8712d5b' # builder UUID.v5(com.saminbun.desktop, official NSIS namespace)
$InstallKey = "HKCU:\Software\$Guid"
$UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$Guid"
$MachineKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$Guid"
$QaProfile = Join-Path $env:APPDATA '3인분'
$ExpectedInstall = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\saminbun-desktop'))
if ((Test-Path $InstallKey) -or (Test-Path $UninstallKey) -or (Test-Path $MachineKey) -or (Test-Path -LiteralPath $QaProfile) -or
    (Test-Path -LiteralPath $ExpectedInstall) -or (Get-Process -Name saminbun -ErrorAction SilentlyContinue)) { throw 'QA_REFUSES_EXISTING_INSTALL_OR_PROFILE' }
$Token = [guid]::NewGuid().ToString()
$Evidence = Join-Path ([IO.Path]::GetTempPath()) "saminbun-update-smoke-$Token"
New-Item -ItemType Directory -Path $Evidence | Out-Null
$Sentinel = Join-Path $QaProfile 'saminbun-synthetic-update-sentinel.txt'
$ProfileSentinels = @('qa-preservation', 'platform-profiles', 'ad-profiles', 'order-profiles-ohouse', 'order-profiles-coupang-wing') | ForEach-Object {
  Join-Path $QaProfile (Join-Path $_ 'qa-synthetic-preservation.txt')
}
function Assert-ProfilePreserved {
  foreach ($File in @($Sentinel) + $ProfileSentinels) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or [IO.File]::ReadAllText($File) -ne $Token) { throw 'SYNTHETIC_PROFILE_FILE_CHANGED' }
  }
}
$OwnedPids = [Collections.Generic.List[int]]::new()
$InstalledHere = $false
$AppExe = $null
$QaCertificate = $null
$FixtureProcess = $null
$FixtureKey = $null
$FixtureUrl = $null
$FixtureJobId = $null
$Result = [ordered]@{ fromVersion=$FromVersion; toVersion=$ToVersion; completed=$false; stage='initial'; productionLoginPerformed=$false }

function New-ExactStartInfo([string]$File, [string[]]$Arguments) {
  $Info = [Diagnostics.ProcessStartInfo]::new($File); $Info.UseShellExecute = $false
  $Info.Environment.Clear()
  foreach ($Key in @('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOMEDRIVE','HOMEPATH','COMSPEC','ProgramFiles','ProgramFiles(x86)','CommonProgramFiles','GITHUB_ACTIONS','RUNNER_OS','RUNNER_ENVIRONMENT','GITHUB_REPOSITORY')) {
    $Value = [Environment]::GetEnvironmentVariable($Key)
    if ($Value) { $Info.Environment[$Key] = $Value }
  }
  foreach ($Argument in $Arguments) { $Info.ArgumentList.Add($Argument) }
  return $Info
}
function Start-ExactProcess([string]$File, [string[]]$Arguments) {
  return [Diagnostics.Process]::Start((New-ExactStartInfo $File $Arguments))
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$Code) {
  $Until = [DateTime]::UtcNow.AddSeconds($Seconds)
  do { $Value = & $Condition; if ($Value) { return $Value }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $Until)
  throw $Code
}
function Invoke-Bridge([string]$Mode, [int]$Port) {
  $Info = New-ExactStartInfo $Node @($Helper, '--endpoint', "http://127.0.0.1:$Port", '--mode', $Mode, '--from', $FromVersion, '--to', $ToVersion, '--sentinel', $Token)
  if ($Mode -in @('server-start', 'server-readback')) {
    $Info.ArgumentList.Add('--fixture-url'); $Info.ArgumentList.Add($FixtureUrl)
    if ($FixtureJobId) { $Info.ArgumentList.Add('--job-id'); $Info.ArgumentList.Add($FixtureJobId) }
  }
  $Info.RedirectStandardOutput = $true; $Info.RedirectStandardError = $true
  $Bridge = [Diagnostics.Process]::Start($Info)
  $Output = $Bridge.StandardOutput.ReadToEndAsync(); $Diagnostic = $Bridge.StandardError.ReadToEndAsync()
  if (-not $Bridge.WaitForExit(780000)) { $Bridge.Kill(); throw "BRIDGE_PHASE_TIMEOUT_$Mode" }
  $null = $Diagnostic.GetAwaiter().GetResult()
  if ($Bridge.ExitCode -ne 0) { throw "BRIDGE_PHASE_FAILED_$Mode" }
  return ($Output.GetAwaiter().GetResult() | ConvertFrom-Json)
}
function Free-Port {
  $Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $Listener.Start()
  try { return $Listener.LocalEndpoint.Port } finally { $Listener.Stop() }
}
function Start-QaApp([int]$Port) {
  $Info = New-ExactStartInfo $AppExe @('--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$Port")
  if ($QaCertificate) { $Info.Environment['NODE_EXTRA_CA_CERTS'] = $QaCertificate }
  $Process = [Diagnostics.Process]::Start($Info)
  $OwnedPids.Add($Process.Id)
  Wait-Until { try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 1; return $true } catch { return $false } } 30 'CDP_LOOPBACK_UNAVAILABLE' | Out-Null
  return $Process
}
function Invoke-NativeButton([int]$OwnerPid, [string]$ButtonName) {
  $Dialog = Wait-Until {
    $Conditions = [Windows.Automation.AndCondition]::new(
      [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $OwnerPid),
      [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, '3인분 업데이트'))
    return [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $Conditions)
  } 20 'NATIVE_CONFIRM_DIALOG_UNAVAILABLE'
  $Condition = [Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $ButtonName),
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
  $Button = $Dialog.FindFirst([Windows.Automation.TreeScope]::Descendants, $Condition)
  if (-not $Button -or -not $Button.Current.IsEnabled) { throw 'NATIVE_CONFIRM_BUTTON_UNAVAILABLE' }
  $Pattern = $Button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
  $Pattern.Invoke()
}
function Close-OwnedApp([Diagnostics.Process]$Process) {
  if (-not $OwnedPids.Contains($Process.Id)) { throw 'PROCESS_NOT_OWNED' }
  if (-not $Process.HasExited) {
    Wait-Until { $Process.Refresh(); return $Process.MainWindowHandle -ne [IntPtr]::Zero } 20 'OWNED_APP_MAIN_WINDOW_UNAVAILABLE' | Out-Null
    if (-not $Process.CloseMainWindow() -or -not $Process.WaitForExit(15000)) { throw 'OWNED_APP_GRACEFUL_CLOSE_FAILED' }
  }
}


# Read-only diagnostics for this synthetic VM's exact installer process tree.
# No command lines, environment values, UI ValuePattern, profile content or clicks.
function Protect-QaDiagnosticText([string]$Value) {
  if (-not $Value) { return '' }
  foreach ($RootName in @('USERPROFILE', 'TEMP', 'TMP', 'APPDATA', 'LOCALAPPDATA')) {
    $RootValue = [Environment]::GetEnvironmentVariable($RootName)
    if ($RootValue) { $Value = $Value.Replace($RootValue, "<$RootName>") }
  }
  $Value = $Value.Replace($Token, '<qa-run-id>') -replace '[\x00-\x1f]', ' '
  if ($Value.Length -gt 180) { return $Value.Substring(0, 180) + '...' }
  return $Value
}
function Get-InitialInstallDiagnostic([Diagnostics.Process]$SetupProcess, [Collections.Generic.HashSet[int]]$TrackedIds, [int]$ElapsedSeconds) {
  $Diagnostic = [ordered]@{
    elapsedSeconds=$ElapsedSeconds; setupPid=$SetupProcess.Id; parentSessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId
    userInteractive=[Environment]::UserInteractive; parent64Bit=[Environment]::Is64BitProcess
    setupExited=$false; setupExitCode=$null; processQueryAvailable=$false; processes=@(); windows=@()
    installRegistryPresent=(Test-Path -LiteralPath $InstallKey); uninstallRegistryPresent=(Test-Path -LiteralPath $UninstallKey)
    machineUninstallRegistryPresent=(Test-Path -LiteralPath $MachineKey); expectedInstallDirectoryPresent=(Test-Path -LiteralPath $ExpectedInstall)
    expectedExePresent=(Test-Path -LiteralPath (Join-Path $ExpectedInstall 'saminbun.exe'))
    expectedUninstallerPresent=(Test-Path -LiteralPath (Join-Path $ExpectedInstall 'Uninstall saminbun.exe'))
    expectedAsarPresent=$false; expectedAsarBytes=$null; profileDirectoryPresent=(Test-Path -LiteralPath $QaProfile)
  }
  try {
    $SetupProcess.Refresh(); $Diagnostic.setupExited = $SetupProcess.HasExited
    if ($Diagnostic.setupExited) { $Diagnostic.setupExitCode = $SetupProcess.ExitCode }
  } catch { $Diagnostic.setupProcessInspectionUnavailable=$true }
  $AsarPath = Join-Path $ExpectedInstall 'resources\app.asar'
  if (Test-Path -LiteralPath $AsarPath -PathType Leaf) {
    $Diagnostic.expectedAsarPresent=$true
    try { $Diagnostic.expectedAsarBytes=(Get-Item -LiteralPath $AsarPath).Length } catch { }
  }
  try {
    $All = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,SessionId,ReadTransferCount,WriteTransferCount -ErrorAction Stop)
    for ($Depth=0; $Depth -lt 8; $Depth++) {
      $Added=$false
      foreach ($Entry in $All) {
        if ($TrackedIds.Count -lt 32 -and $TrackedIds.Contains([int]$Entry.ParentProcessId) -and -not $TrackedIds.Contains([int]$Entry.ProcessId)) {
          $null=$TrackedIds.Add([int]$Entry.ProcessId); $Added=$true
        }
      }
      if (-not $Added) { break }
    }
    $Diagnostic.processQueryAvailable=$true
    $Diagnostic.processes=@($All | Where-Object { $TrackedIds.Contains([int]$_.ProcessId) } | Select-Object -First 32 | ForEach-Object {
      [ordered]@{ pid=[int]$_.ProcessId; parentPid=[int]$_.ParentProcessId; sessionId=$_.SessionId
        executableName=(Protect-QaDiagnosticText $_.Name); executablePath=(Protect-QaDiagnosticText $_.ExecutablePath)
        readTransferBytes=$_.ReadTransferCount; writeTransferBytes=$_.WriteTransferCount }
    })
  } catch { $Diagnostic.processQueryAvailable=$false }
  try {
    $TopWindows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
    $Windows=[Collections.Generic.List[object]]::new()
    foreach ($TopWindow in $TopWindows) {
      if ($Windows.Count -ge 6) { break }
      if (-not $TrackedIds.Contains([int]$TopWindow.Current.ProcessId)) { continue }
      $Controls=[Collections.Generic.List[object]]::new()
      $Elements=$TopWindow.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
      foreach ($Element in $Elements) {
        if ($Controls.Count -ge 24) { break }
        # Name only; never read input values or invoke any UI control.
        if ($Element.Current.IsPassword) { continue }
        $Name=Protect-QaDiagnosticText $Element.Current.Name
        if ($Name) { $Controls.Add([ordered]@{ type=$Element.Current.ControlType.ProgrammaticName; name=$Name; enabled=$Element.Current.IsEnabled }) }
      }
      $Windows.Add([ordered]@{ pid=$TopWindow.Current.ProcessId; title=(Protect-QaDiagnosticText $TopWindow.Current.Name); enabled=$TopWindow.Current.IsEnabled; controls=@($Controls.ToArray()) })
    }
    $Diagnostic.windows=@($Windows.ToArray()); $Diagnostic.uiQueryAvailable=$true
  } catch { $Diagnostic.uiQueryAvailable=$false }
  return $Diagnostic
}
function Wait-InitialInstaller([Diagnostics.Process]$SetupProcess) {
  # Keep the original 120-second bound; observe before choosing a new timeout.
  $Watch=[Diagnostics.Stopwatch]::StartNew()
  $TrackedIds=[Collections.Generic.HashSet[int]]::new(); $null=$TrackedIds.Add($SetupProcess.Id)
  $Snapshots=[Collections.Generic.List[object]]::new()
  $Result.initialInstallerDiagnostics=$Snapshots
  $ForwardedNames=@('SystemRoot','WINDIR','PATH','PATHEXT','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOMEDRIVE','HOMEPATH','COMSPEC','ProgramFiles','ProgramFiles(x86)','CommonProgramFiles','GITHUB_ACTIONS','RUNNER_OS','RUNNER_ENVIRONMENT','GITHUB_REPOSITORY')
  $Result.initialInstallerEnvironmentPresence=@(@('SystemRoot','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','ProgramData','ALLUSERSPROFILE','USERNAME','OS','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','SESSIONNAME') | ForEach-Object {
    [ordered]@{ name=$_; parentPresent=[bool][Environment]::GetEnvironmentVariable($_); forwarded=($ForwardedNames -contains $_) }
  })
  foreach ($Checkpoint in @(2,15,60,120)) {
    $Remaining=[Math]::Max(0, [int](($Checkpoint-$Watch.Elapsed.TotalSeconds)*1000))
    $Exited=$SetupProcess.WaitForExit($Remaining)
    $Snapshots.Add((Get-InitialInstallDiagnostic $SetupProcess $TrackedIds ([int]$Watch.Elapsed.TotalSeconds)))
    if ($Exited) {
      $Result.initialInstallerExitCode=$SetupProcess.ExitCode
      if ($SetupProcess.ExitCode -ne 0) { throw 'INITIAL_NSIS_EXIT_NONZERO' }
      return
    }
  }
  # A final state distinction avoids conflating a deadline with a nonzero exit.
  $SetupProcess.Refresh()
  if ($SetupProcess.HasExited) {
    $Result.initialInstallerExitCode=$SetupProcess.ExitCode
    if ($SetupProcess.ExitCode -ne 0) { throw 'INITIAL_NSIS_EXIT_NONZERO' }
    return
  }
  $Result.initialInstallerTimeoutSeconds=120
  throw 'INITIAL_NSIS_TIMEOUT'
}

try {
  try { Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes }
  catch {
    $Wpf = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF'
    Add-Type -Path (Join-Path $Wpf 'UIAutomationTypes.dll')
    Add-Type -Path (Join-Path $Wpf 'UIAutomationClient.dll')
  }
  $Result.stage = 'install-old'
  $Setup = Start-ExactProcess $Installer @('/S')
  Wait-InitialInstaller $Setup
  $Location = [IO.Path]::GetFullPath((Get-ItemProperty -LiteralPath $InstallKey).InstallLocation)
  if ($Location -ine $ExpectedInstall) { throw 'INSTALL_LOCATION_UNEXPECTED' }
  $AppExe = Join-Path $Location 'saminbun.exe'
  if (-not (Test-Path -LiteralPath $AppExe -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $Location 'Uninstall saminbun.exe') -PathType Leaf)) { throw 'EXACT_INSTALLED_FILES_MISSING' }
  $InstalledHere = $true
  if ((Get-ItemProperty -LiteralPath $UninstallKey).DisplayVersion -ne $FromVersion) { throw 'INITIAL_REGISTRY_VERSION_MISMATCH' }
  if (Test-Path -LiteralPath $QaProfile) { throw 'SILENT_INSTALL_UNEXPECTEDLY_STARTED_APP' }
  New-Item -ItemType Directory -Path $QaProfile | Out-Null
  [IO.File]::WriteAllText($Sentinel, $Token)
  foreach ($File in $ProfileSentinels) {
    New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($File, $Token)
  }
  $Port = Free-Port; $Old = Start-QaApp $Port
  $Result.stage = 'main-check-download'
  $Result.download = Invoke-Bridge 'prepare' $Port
  $Result.stage = 'native-cancel'
  $null = Invoke-Bridge 'request-install' $Port
  Invoke-NativeButton $Old.Id '취소'
  $Result.cancel = Invoke-Bridge 'cancel-check' $Port
  $Result.stage = 'native-confirm-install'
  $null = Invoke-Bridge 'request-install' $Port
  $UpgradeStarted = [DateTime]::Now
  Invoke-NativeButton $Old.Id '저장했고, 재시작하기'
  if (-not $Old.WaitForExit(60000)) { throw 'OLD_APP_DID_NOT_EXIT' }
  $NewInfo = Wait-Until {
    return Get-CimInstance Win32_Process -Filter "Name='saminbun.exe'" | Where-Object {
      $_.ExecutablePath -ieq $AppExe -and $_.ProcessId -ne $Old.Id -and $_.CreationDate -ge $UpgradeStarted -and $_.CommandLine -notmatch '--type='
    } | Select-Object -First 1
  } 180 'AUTOMATIC_RELAUNCH_NOT_OBSERVED'
  $New = Get-Process -Id $NewInfo.ProcessId; $OwnedPids.Add($New.Id)
  if ((Get-Item -LiteralPath $AppExe).VersionInfo.ProductVersion -ne $ToVersion -or
      (Get-ItemProperty -LiteralPath $UninstallKey).DisplayVersion -ne $ToVersion) { throw 'UPDATED_FILE_OR_REGISTRY_VERSION_MISMATCH' }
  $Result.automaticRelaunchObserved = $true
  $Result.automaticRelaunchHadNewPid = $true
  $Result.autoWindowVersionTextObserved = $false
  try {
    $Window = [Windows.Automation.AutomationElement]::FromHandle($New.MainWindowHandle)
    $Texts = $Window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($Text in $Texts) { if ($Text.Current.Name -in @("v$ToVersion", "3인분 데스크톱 · $ToVersion")) { $Result.autoWindowVersionTextObserved = $true; break } }
  } catch { $Result.autoWindowVersionTextObserved = $false }
  Assert-ProfilePreserved
  $Result.syntheticProfileFilesPreservedAfterUpdate = 6
  $Result.stage = 'independent-restart-readback'
  Wait-Until { $New.Refresh(); return $New.MainWindowHandle -ne [IntPtr]::Zero } 30 'AUTO_RELAUNCH_WINDOW_UNAVAILABLE' | Out-Null
  Close-OwnedApp $New
  $Port = Free-Port; $Verified = Start-QaApp $Port
  $Result.readback = Invoke-Bridge 'verify' $Port
  Assert-ProfilePreserved
  Close-OwnedApp $Verified
  $Result.stage = 'synthetic-https-fixture'
  $OpenSsl = Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $OpenSslPath = if ($OpenSsl) { $OpenSsl.Source } else { Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe' }
  if (-not (Test-Path -LiteralPath $OpenSslPath -PathType Leaf)) { throw 'OWNED_FIXTURE_OPENSSL_MISSING' }
  $QaCertificate = Join-Path $Evidence 'synthetic-ca.pem'
  $FixtureKey = Join-Path $Evidence 'synthetic-key.pem'
  $FixtureReport = Join-Path $Evidence 'synthetic-server-report.json'
  $OpenSslConfig = Join-Path $Evidence 'synthetic-openssl.cnf'
  [IO.File]::WriteAllText($OpenSslConfig, "[req]`ndistinguished_name=dn`n[dn]`n")
  $ClosedMarker = Join-Path $Evidence 'owned-app-closed.json'
  $CertificateProcess = Start-ExactProcess $OpenSslPath @('req', '-config', $OpenSslConfig, '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-days', '1', '-subj', '/CN=Saminbun Synthetic Loopback QA', '-addext', 'subjectAltName=IP:127.0.0.1', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,digitalSignature,keyCertSign', '-addext', 'extendedKeyUsage=serverAuth', '-keyout', $FixtureKey, '-out', $QaCertificate)
  if (-not $CertificateProcess.WaitForExit(30000) -or $CertificateProcess.ExitCode -ne 0) { throw 'OWNED_FIXTURE_CERTIFICATE_FAILED' }
  $FixturePort = Free-Port
  $FixtureUrl = "https://127.0.0.1:$FixturePort/api/desktop"
  $FixtureProcess = Start-ExactProcess $Node @((Join-Path $PSScriptRoot 'windows-server-fixture.mjs'), $FixtureKey, $QaCertificate, $FixtureReport, $ClosedMarker, [string]$FixturePort)
  Wait-Until {
    if ($FixtureProcess.HasExited) { throw 'OWNED_FIXTURE_EXITED' }
    try { return (Get-Content -LiteralPath $FixtureReport -Raw | ConvertFrom-Json).ready } catch { return $false }
  } 15 'OWNED_FIXTURE_NOT_READY' | Out-Null
  $Port = Free-Port; $Observer = Start-QaApp $Port
  $Result.stage = 'real-app-synthetic-server-start'
  $Result.syntheticStart = Invoke-Bridge 'server-start' $Port
  $Accepted = Wait-Until {
    try { $Report = Get-Content -LiteralPath $FixtureReport -Raw | ConvertFrom-Json; if ($Report.job -and $Report.job.status -eq 'collecting' -and $Report.startPosts -eq 1 -and $Report.observerJobGets -gt 0 -and -not $Report.failure) { return $Report } } catch { }
    return $false
  } 10 'SYNTHETIC_SERVER_START_NOT_ACCEPTED'
  $FixtureJobId = $Accepted.job.jobId
  $Result.stage = 'real-app-close-before-synthetic-completion'
  Close-OwnedApp $Observer
  if (-not $Observer.HasExited) { throw 'OWNED_APP_PID_STILL_PRESENT' }
  @{ mainPidGone=$true; closedAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $ClosedMarker -Encoding utf8NoBOM
  $Finished = Wait-Until {
    try { $Report = Get-Content -LiteralPath $FixtureReport -Raw | ConvertFrom-Json; if ($Report.failure) { throw 'SYNTHETIC_SERVER_CONTRACT_FAILED' }; if ($Report.completedAfterAppClosed -and $Report.job.status -eq 'completed') { return $Report } } catch { if ($_.Exception.Message -eq 'SYNTHETIC_SERVER_CONTRACT_FAILED') { throw } }
    return $false
  } 35 'SYNTHETIC_SERVER_DID_NOT_COMPLETE_AFTER_APP_CLOSE'
  if ($FixtureProcess.HasExited -or $Finished.startPosts -ne 1 -or $Finished.forbiddenJobWrites -ne 0 -or -not $Finished.protocol2Observed) { throw 'SYNTHETIC_SERVER_PROCESS_OR_WRITE_ASSERTION_FAILED' }
  $Result.stage = 'real-app-relaunch-synthetic-server-readback'
  $Port = Free-Port; $Readback = Start-QaApp $Port
  $Result.syntheticServerReadback = Invoke-Bridge 'server-readback' $Port
  Close-OwnedApp $Readback
  $FinalFixture = Get-Content -LiteralPath $FixtureReport -Raw | ConvertFrom-Json
  if ($FinalFixture.startPosts -ne 1 -or $FinalFixture.forbiddenJobWrites -ne 0 -or $FinalFixture.failure -or $FinalFixture.revision -ne 2 -or $FinalFixture.job.jobId -ne $FixtureJobId) { throw 'SYNTHETIC_SERVER_FINAL_ASSERTION_FAILED' }
  Assert-ProfilePreserved
  $Result.syntheticServer = [ordered]@{ actualInstalledElectronBridge=$true; actualPassiveJobGetObserved=$true; nativeMainPidExitedBeforeCompletion=$true; independentNodeServiceCompleted=$true; reloadedSameJob=$true; revision=2; startPosts=1; forbiddenStepCompleteCancelWrites=0; protocol2Observed=$true; tlsVerificationPreserved=$true; ephemeralCaScopedToOwnedAppChild=$true; productionBackendTested=$false }
  $Result.stage = 'uninstall-retains-data'
  $Uninstaller = Join-Path $Location 'Uninstall saminbun.exe'
  $Removal = Start-ExactProcess $Uninstaller @('/S')
  if (-not $Removal.WaitForExit(90000)) { throw 'UNINSTALL_TIMEOUT' }
  Wait-Until { -not (Test-Path $UninstallKey) -and -not (Test-Path -LiteralPath $AppExe) } 45 'UNINSTALL_NOT_CONFIRMED' | Out-Null
  Assert-ProfilePreserved
  $Result.syntheticProfileFilesPreservedAfterUninstall = 6
  $Result.uninstallerRegistryRemoved = $true; $Result.syntheticUserDataRetained = $true
  $Result.completed = $true; $Result.stage = 'complete'
} finally {
  if ($FixtureProcess -and -not $FixtureProcess.HasExited) { $FixtureProcess.Kill(); $FixtureProcess.WaitForExit(5000) | Out-Null }
  # Only processes started/identified by this run and this exact installed path.
  foreach ($OwnedPid in $OwnedPids) {
    try {
      $Process = Get-Process -Id $OwnedPid -ErrorAction SilentlyContinue
      if ($Process -and $AppExe -and $Process.Path -ieq $AppExe) { Stop-Process -Id $OwnedPid -Force }
    } catch { $Result.cleanupProcessWarning = $true }
  }
  foreach ($OwnedCertificateFile in @($QaCertificate, $FixtureKey)) {
    if ($OwnedCertificateFile -and (Test-Path -LiteralPath $OwnedCertificateFile -PathType Leaf)) { Remove-Item -LiteralPath $OwnedCertificateFile -Force }
  }
  # No broad cleanup, no recursive deletion of profiles. Fresh VM disposal owns
  # final cleanup; partial failures preserve evidence and never claim success.
  $Result.installedByThisRun = $InstalledHere
  $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding utf8
  $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Evidence 'result.json') -Encoding utf8
  $Result | ConvertTo-Json -Depth 12
}
