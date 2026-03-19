$ErrorActionPreference = "Continue"

$Win32Definition = @"
using System;
using System.Runtime.InteropServices;
public class MemoryApi {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@

try {
    if (-not ([System.Management.Automation.PSTypeName]'MemoryApi').Type) {
        Add-Type -TypeDefinition $Win32Definition -ErrorAction SilentlyContinue
    }
} catch {
}

function Get-ProcessStats {
    param([System.Diagnostics.Process[]]$ProcessList)
    
    $stats = foreach ($p in $ProcessList) {
        $path = "Access Denied"
        try { $path = $p.MainModule.FileName } catch { }
        
        [PSCustomObject]@{
            Id            = $p.Id
            ProcessName   = $p.ProcessName
            "Memory (MB)" = "{0:N2} MB" -f ($p.WorkingSet64 / 1MB)
            Path          = $path
        }
    }
    return $stats
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Clear-Host
    Write-Host ">>> ELEVATION REQUEST" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
    Write-Host "Current session is NOT running as Administrator."
    Write-Host "Running as Admin allows access to more processes."
    Write-Host ""
    $adminChoice = Read-Host "Would you like to restart as Administrator? (y/n)"
    
    if ($adminChoice -eq 'y') {
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
}

while ($true) {
    Clear-Host
    $status = if ($isAdmin) { "ELEVATED" } else { "STANDARD" }
    $color = if ($isAdmin) { "Green" } else { "Yellow" }
    
    $InputTarget = Read-Host "Input Target (PID or Process Name / 'q' to quit)"
    
    if ([string]::IsNullOrWhiteSpace($InputTarget) -or $InputTarget -eq 'q') { break }

    try {
        $InitialProcess = $null
        if ($InputTarget -as [int]) {
            $InitialProcess = Get-Process -Id $InputTarget -ErrorAction Stop
        } else {
            $cleanName = $InputTarget.Replace(".exe", "")
            $InitialProcess = Get-Process -Name $cleanName -ErrorAction Stop | Select-Object -First 1
        }

        $TargetName = $InitialProcess.ProcessName
        $TargetPath = ""
        try { $TargetPath = $InitialProcess.MainModule.FileName } catch { }
        
        $RelatedProcesses = Get-Process -Name $TargetName | Where-Object {
            if (-not $TargetPath) { return $true }
            $currPath = $null
            try { $currPath = $_.MainModule.FileName } catch { }
            return (-not $currPath -or ($currPath -eq $TargetPath))
        }

        $Stats = Get-ProcessStats -ProcessList $RelatedProcesses
        $TotalBefore = ($RelatedProcesses | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB

        Write-Host "`nTarget Context:" -ForegroundColor Cyan
        Write-Host "  Name  : $($TargetName.ToUpper())"
        Write-Host "  Path  : $(if($TargetPath){$TargetPath}else{"Access Denied/Unknown"})"
        Write-Host "  Nodes : $($RelatedProcesses.Count)"
        Write-Host "  RAM   : $([math]::Round($TotalBefore, 2)) MB"
        Write-Host ""
        
        $Stats | Format-Table -AutoSize

        $Confirmation = Read-Host "Authorize memory flush? (y/n)"
        if ($Confirmation -eq 'y') {
            Write-Host "`nProcessing nodes..." -NoNewline
            
            $success = 0
            foreach ($proc in $RelatedProcesses) {
                try {
                    if ([MemoryApi]::EmptyWorkingSet($proc.Handle)) { $success++ }
                } catch { }
            }
            
            Start-Sleep -Milliseconds 500
            $TotalAfter = (Get-Process -Id ($RelatedProcesses.Id) -ErrorAction SilentlyContinue | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB
            $Gain = [math]::Max(0, $TotalBefore - $TotalAfter)

            Write-Host " Done." -ForegroundColor Green
            Write-Host "--------------------------------------------------"
            Write-Host "Nodes Optimized : $success"
            Write-Host "Memory Released : $([math]::Round($Gain, 2)) MB" -ForegroundColor Magenta
            Write-Host "--------------------------------------------------"
        }

    } catch {
        Write-Host "`n[!] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n[1] Return to Main Menu"
    Write-Host "[Any other key] Exit Utility"
    $FinalChoice = Read-Host "Choice"
    if ($FinalChoice -ne '1') { break }
}
