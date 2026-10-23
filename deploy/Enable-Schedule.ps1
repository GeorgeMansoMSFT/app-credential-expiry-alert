#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$Disable)
. "$PSScriptRoot/Common.ps1"
$config=Read-DigestConfig $ConfigPath
Connect-DigestAzure $config
$base=Get-DigestBase $config
$name='Weekly-Owner-Digest'
if ($Disable) {
    Invoke-DigestArm -Uri "$base/schedules/$($name)?api-version=2024-10-23" -Method PATCH -Body @{properties=@{isEnabled=$false}} | Out-Null
    Write-Host 'Weekly schedule disabled.'
    return
}
$zone=[TimeZoneInfo]::FindSystemTimeZoneById($config.scheduleTimeZone)
$now=[TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow,$zone)
$next=$now.Date.AddHours($config.scheduleHour)
while ($next.DayOfWeek.ToString() -ne $config.scheduleDay -or $next -le $now.AddMinutes(10)) { $next=$next.AddDays(1) }
$start=[datetimeoffset]::new([datetime]::SpecifyKind($next,[DateTimeKind]::Unspecified),$zone.GetUtcOffset($next))
Invoke-DigestArm -Uri "$base/schedules/$($name)?api-version=2024-10-23" -Method PUT -Body @{properties=@{
    description='Weekly credential expiry digest to application owners';startTime=$start.ToString('o');frequency='Week';interval=1
    timeZone=$config.scheduleTimeZone;advancedSchedule=@{weekDays=@($config.scheduleDay)}
}} | Out-Null
Invoke-DigestArm -Uri "$base/schedules/$($name)?api-version=2024-10-23" -Method PATCH -Body @{properties=@{isEnabled=$true}} | Out-Null
$parameters=Get-DigestJobParameters $config
$parameters.SendEmail='true'
# Stable within each account: rerunning does not create a second scheduled job link.
$linkUri="$base/jobSchedules/15035a17-62cf-496d-8f7b-b6ce3d6a20db?api-version=2024-10-23"
$existing=$null
try { $existing=Invoke-DigestArm -Uri $linkUri }
catch { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
$same=$false
if ($existing) {
    $old=$existing.properties.parameters
    $same=$existing.properties.runbook.name -eq 'Send-CredentialDigest' -and $existing.properties.schedule.name -eq $name
    foreach ($key in $parameters.Keys) {
        $property=$old.PSObject.Properties[$key]
        if (!$property -or [string]$property.Value -ne [string]$parameters[$key]) { $same=$false }
    }
    if ($old.PSObject.Properties.Name -contains 'TestRecipient' -or $old.PSObject.Properties.Name -contains 'ApplicationIds') { $same=$false }
    # Azure job schedule bindings are create/delete, so replace only this known binding when parameters change.
    if (!$same) { Invoke-DigestArm -Uri $linkUri -Method DELETE | Out-Null }
}
if (!$same) { Invoke-DigestArm -Uri $linkUri -Method PUT -Body @{properties=@{
    schedule=@{name=$name};runbook=@{name='Send-CredentialDigest'};parameters=$parameters
}} | Out-Null }
$schedule=Invoke-DigestArm -Uri "$base/schedules/$($name)?api-version=2024-10-23"
$schedule.properties | Select-Object isEnabled,nextRun,timeZone,frequency
