#Requires -Version 7.4
# Simulated Azure API checks. No Azure requests or emails are made.
$ErrorActionPreference='Stop'
$global:digestScheduleState=@{Link=$null;Creates=0;Deletes=0;Schedule=$null}
$global:digestScheduleConfig=Get-Content "$PSScriptRoot/config.example.json" -Raw | ConvertFrom-Json -AsHashtable
$global:digestScheduleConfig.tenantId=[guid]::NewGuid().ToString()
$global:digestScheduleConfig.subscriptionId=[guid]::NewGuid().ToString()
$global:LASTEXITCODE=0
function global:az {
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
        @{tenantId=$global:digestScheduleConfig.tenantId;id=$global:digestScheduleConfig.subscriptionId} | ConvertTo-Json -Compress
    } elseif ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
        '{"accessToken":"offline-test-token"}'
    } else { throw "Unexpected Azure CLI call: $args" }
}
function global:Invoke-RestMethod {
    param($Uri,$Method,$Authentication,$Token,$ErrorAction,$Body,$ContentType)
    $state=$global:digestScheduleState
    if ($Uri -match '/jobSchedules/') {
        switch ($Method) {
            GET {
                if ($null -eq $state.Link) {
                    $failure=[Exception]::new('Not found')
                    $failure | Add-Member -NotePropertyName Response -NotePropertyValue @{StatusCode=404}
                    throw $failure
                }
                return $state.Link
            }
            PUT { $state.Link=$Body | ConvertFrom-Json; $state.Creates++; return }
            DELETE { $state.Link=$null; $state.Deletes++; return }
        }
    }
    if ($Uri -match '/schedules/') {
        switch ($Method) {
            PUT { $state.Schedule=$Body | ConvertFrom-Json; return }
            PATCH {
                if ($null -eq $state.Schedule) {
                    $failure=[Exception]::new('Not found')
                    $failure | Add-Member -NotePropertyName Response -NotePropertyValue @{StatusCode=404}
                    throw $failure
                }
                $state.Enabled=($Body | ConvertFrom-Json).properties.isEnabled; return
            }
            GET { return @{properties=@{isEnabled=$state.Enabled;nextRun=$state.Schedule.properties.startTime;timeZone=$state.Schedule.properties.timeZone;frequency='Week'}} }
        }
    }
    throw "Unexpected request: $Method $Uri"
}
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$path=[IO.Path]::GetTempFileName()
try {
    $global:digestScheduleConfig | ConvertTo-Json | Set-Content -LiteralPath $path
    & "$PSScriptRoot/Enable-Schedule.ps1" -ConfigPath $path -Disable 6>$null | Out-Null
    Assert ($null -eq $global:digestScheduleState.Schedule) 'Disable before activation created a schedule.'
    & "$PSScriptRoot/Enable-Schedule.ps1" -ConfigPath $path | Out-Null
    Assert ($global:digestScheduleState.Creates -eq 1) 'First run did not create exactly one binding.'
    Assert ($global:digestScheduleState.Link.properties.parameters.SendEmail -eq 'true') 'Schedule did not enable sending.'
    Assert ($global:digestScheduleState.Link.properties.parameters.PSObject.Properties.Name -notcontains 'TestRecipient') 'Schedule retained a test override.'
    & "$PSScriptRoot/Enable-Schedule.ps1" -ConfigPath $path | Out-Null
    Assert ($global:digestScheduleState.Creates -eq 1 -and $global:digestScheduleState.Deletes -eq 0) 'Identical repeat run duplicated or replaced the binding.'
    $global:digestScheduleConfig.fallbackRecipient='updated@contoso.com'
    $global:digestScheduleConfig | ConvertTo-Json | Set-Content -LiteralPath $path
    & "$PSScriptRoot/Enable-Schedule.ps1" -ConfigPath $path | Out-Null
    Assert ($global:digestScheduleState.Creates -eq 2 -and $global:digestScheduleState.Deletes -eq 1) 'Changed parameters did not replace the single binding.'
    Assert ($global:digestScheduleState.Link.properties.parameters.FallbackRecipient -eq 'updated@contoso.com') 'Updated fallback not stored.'
    & "$PSScriptRoot/Enable-Schedule.ps1" -ConfigPath $path -Disable | Out-Null
    Assert (!$global:digestScheduleState.Enabled) 'Disable did not stop the schedule.'
    'PASS: disable before activation, first activation, owner routing, repeat activation, parameter update, and disable.'
} finally {
    Remove-Item -LiteralPath $path -Force
    Remove-Item Function:\az,Function:\Invoke-RestMethod
    Remove-Variable digestScheduleState,digestScheduleConfig -Scope Global -ErrorAction SilentlyContinue
}
