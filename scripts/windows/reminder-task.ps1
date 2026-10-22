param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Register", "Run", "SelfTest", "SelfTestRun")]
    [string]$Mode,
    [string]$Distro,
    [string]$RepoPath,
    [ValidatePattern("^[A-Za-z0-9._-]{1,100}$")]
    [string]$OpId,
    [string]$LaunchTime,
    [ValidateRange(1, 4320)]
    [int]$ReminderMinutes = 240,
    [string]$MarkerPath
)

$ErrorActionPreference = "Stop"

function New-WslTaskAction([string]$taskMode, [string]$extraArgs) {
    $scriptPath = $PSCommandPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Distro "{2}" -RepoPath "{3}" {4}' -f `
        $scriptPath, $taskMode, $Distro, $RepoPath, $extraArgs
    return New-ScheduledTaskAction -Execute (Join-Path $PSHOME "powershell.exe") -Argument $arguments
}

if ($Mode -eq "SelfTestRun") {
    try {
        $wsl = Join-Path $env:WINDIR "System32\wsl.exe"
        if (-not (Test-Path $wsl)) {
            throw "wsl.exe was not found."
        }
        Set-Content -LiteralPath $MarkerPath -Value "RUNNING" -Encoding UTF8
        $testOutput = & $wsl -d $Distro --cd $RepoPath -- bash scripts/reminder-self-test.sh 2>&1 | Out-String
        $testExitCode = $LASTEXITCODE
        if ($testExitCode -ne 0) {
            throw "WSL test returned exit code $testExitCode. $testOutput"
        }
        Set-Content -LiteralPath $MarkerPath -Value ("SUCCESS`n" + ($testOutput | Out-String)) -Encoding UTF8
        exit 0
    }
    catch {
        Set-Content -LiteralPath $MarkerPath -Value "ERROR: $_" -Encoding UTF8
        exit 1
    }
}

$taskName = "TwinLabReminder-$OpId"
if ($Mode -eq "Register") {
    if (-not $OpId -or $OpId -notmatch "^[A-Za-z0-9._-]{1,100}$" -or -not $LaunchTime) {
        throw "Register mode requires a valid operation ID and launch time."
    }
    $launch = [DateTimeOffset]::Parse(
        $LaunchTime,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    $deadline = $launch.AddMinutes($ReminderMinutes).LocalDateTime
    if ($deadline -le [DateTime]::Now) {
        $deadline = [DateTime]::Now.AddSeconds(30)
    }

    $extraArgs = '-OpId "{0}" -LaunchTime "{1}" -ReminderMinutes {2}' -f $OpId, $LaunchTime, $ReminderMinutes
    $action = New-WslTaskAction "Run" $extraArgs
    $trigger = New-ScheduledTaskTrigger -Once -At $deadline
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 4 `
        -RestartInterval (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Description "TwinLab running-time reminder for $OpId" `
        -Principal $principal -Force | Out-Null
    Write-Output "Registered Windows task '$taskName' for $deadline."
    exit 0
}

if ($Mode -eq "SelfTest") {
    if (-not $Distro -or -not $RepoPath) {
        throw "SelfTest mode requires a WSL distro and repository path."
    }
    $testId = [Guid]::NewGuid().ToString("N")
    $taskName = "TwinLabReminderTest-$testId"
    $markerPath = Join-Path $env:TEMP "$taskName.txt"
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    $extraArgs = '-MarkerPath "{0}"' -f $markerPath
    $action = New-WslTaskAction "SelfTestRun" $extraArgs
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    $testSucceeded = $false
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description "Temporary TwinLab WSL scheduler test" `
            -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $markerPath) {
                $markerContents = Get-Content -LiteralPath $markerPath -Raw
                if (-not $markerContents.StartsWith("RUNNING")) {
                    break
                }
            }
            Start-Sleep -Seconds 1
        }
        if (-not (Test-Path -LiteralPath $markerPath)) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
            $task = Get-ScheduledTask -TaskName $taskName
            throw "Scheduled task did not launch its action within 45 seconds (state=$($task.State), result=$($taskInfo.LastTaskResult)). Task: '$taskName'."
        }
        $result = Get-Content -LiteralPath $markerPath -Raw
        if ($result.StartsWith("ERROR:")) {
            throw "$($result.Trim()) Test output retained at $markerPath"
        }
        if (-not $result.StartsWith("SUCCESS")) {
            throw "Scheduled task did not finish successfully. Task '$taskName'. Test output retained at $markerPath"
        }
        $result = $result.Substring("SUCCESS".Length)
        Write-Output $result.Trim()
        Write-Output "Windows Task Scheduler launched WSL successfully."
        $testSucceeded = $true
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($testSucceeded) {
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
    }
    exit 0
}

$exitCode = 1
try {
    if (-not $OpId -or -not $LaunchTime) {
        throw "Run mode requires an operation ID and launch time."
    }
    $wsl = Join-Path $env:WINDIR "System32\wsl.exe"
    if (-not (Test-Path $wsl)) {
        throw "wsl.exe was not found."
    }
    & $wsl -d $Distro --cd $RepoPath -- bash scripts/reminder.sh $OpId $LaunchTime
    $exitCode = $LASTEXITCODE
}
finally {
    if ($exitCode -eq 0) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
exit $exitCode
