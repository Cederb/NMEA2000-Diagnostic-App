[CmdletBinding()]
param(
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $PSScriptRoot "..\dist\NMEA2000Diagnostics.exe"
}
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$testRoot = Join-Path $PSScriptRoot ("..\.build\verification-" + [Guid]::NewGuid().ToString("N"))
$testRoot = [System.IO.Path]::GetFullPath($testRoot)
[void][System.IO.Directory]::CreateDirectory($testRoot)

function Assert-Portable {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PortableWindowTest
{
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static IntPtr Find(int processId, string title)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId)
            {
                StringBuilder text = new StringBuilder(512);
                GetWindowText(window, text, text.Capacity);
                if (text.ToString() == title)
                {
                    result = window;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static bool Close(IntPtr window)
    {
        return PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($ExecutablePath))
$resourceStream = $assembly.GetManifestResourceStream("NMEA2000Diagnostics.ps1")
Assert-Portable ($null -ne $resourceStream) "The executable has no embedded application."
$resourceReader = New-Object System.IO.StreamReader($resourceStream)
try {
    $embeddedSource = $resourceReader.ReadToEnd()
}
finally {
    $resourceReader.Dispose()
}

$originalSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\NMEA2000Diagnostics.ps1"))
Assert-Portable ($embeddedSource -ceq $originalSource) "The embedded source differs from the current application."

$messageLoop = '[void][System.Windows.Forms.Application]::Run($form)'
Assert-Portable ($embeddedSource.Contains($messageLoop)) "The application entry point could not be found."

try {
    Invoke-Expression ($embeddedSource.Replace($messageLoop, ""))
    Assert-Portable ($tabs.TabPages.Count -eq 4) "The expected diagnostic views were not created."
    Assert-Portable ($modeCombo.SelectedItem -eq "Silent") "Silent mode is not the default."
    Assert-Portable ($baudCombo.SelectedItem -eq "2000000") "The 2 Mbps adapter default was not preserved."
    Assert-Portable ($connectButton.Enabled -and -not $disconnectButton.Enabled) "Initial connection controls are incorrect."
    Assert-Portable (-not $recordButton.Enabled -and -not $stopRecordingButton.Enabled) "Recording should be disabled until connected."

    [byte[]]$silentConfig = New-WaveshareConfigPacket -Mode "Silent"
    [byte[]]$normalConfig = New-WaveshareConfigPacket -Mode "Normal"
    Assert-Portable ($silentConfig.Length -eq 20 -and $silentConfig[13] -eq 1 -and $normalConfig[13] -eq 0) "Mode configuration packets are incorrect."

    [byte[]]$frame = @(0xAA, 0xE8, 0x20, 0xFF, 0xEE, 0x18, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x55)
    foreach ($value in $frame[0..6]) {
        $Script:RxBuffer.Add($value)
    }
    Parse-RxBuffer
    Assert-Portable ($Script:TotalFrames -eq 0) "A partial receive packet was decoded too early."
    foreach ($value in $frame[7..14]) {
        $Script:RxBuffer.Add($value)
    }
    Parse-RxBuffer
    Update-Ui

    Assert-Portable ($Script:TotalFrames -eq 1 -and $Script:Pgns.ContainsKey(60928)) "The embedded parser did not decode PGN 60928."
    Assert-Portable ($Script:Devices[32].NameHex -eq "0x0807060504030201") "The device NAME was not decoded correctly."
    Assert-Portable ($pgnGrid.Rows.Count -eq 1 -and $deviceGrid.Rows.Count -eq 1 -and $rawGrid.Rows.Count -eq 1) "Captured data did not reach the UI tables."

    $modeCombo.SelectedItem = "Normal"
    Assert-Portable ($Script:CurrentMode -eq "Normal") "The mode dropdown callback failed."
    Clear-CapturedData
    Assert-Portable ($Script:TotalFrames -eq 0 -and $Script:Devices.Count -eq 0 -and $pgnGrid.Rows.Count -eq 0) "Clear Capture did not reset the data and tables."
}
finally {
    if ($null -ne $form) {
        Disconnect-Adapter -Quiet
        $uiTimer.Stop()
        $uiTimer.Dispose()
        $pollTimer.Dispose()
        $form.Dispose()
    }
}

# Launch a copy from a directory containing only the EXE to detect sidecar dependencies.
$isolatedExecutable = Join-Path $testRoot "NMEA2000Diagnostics.exe"
Copy-Item -LiteralPath $ExecutablePath -Destination $isolatedExecutable
$appProcess = $null
$appWindow = [IntPtr]::Zero
try {
    $appProcess = Start-Process -FilePath $isolatedExecutable -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 200
        $appProcess.Refresh()
        $appWindow = [PortableWindowTest]::Find($appProcess.Id, "NMEA2000 Bus Diagnostics - Waveshare USB-CAN-A")
    } while (-not $appProcess.HasExited -and $appWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)

    Assert-Portable (-not $appProcess.HasExited) "The portable executable exited before showing its window."
    Assert-Portable ($appWindow -ne [IntPtr]::Zero) "The expected application window was not created."
    Start-Sleep -Seconds 2
    $appProcess.Refresh()
    Assert-Portable (-not $appProcess.HasExited) "The app failed while running its UI timer."
    Assert-Portable ([PortableWindowTest]::Close($appWindow)) "The app window could not be closed."
    Assert-Portable ($appProcess.WaitForExit(10000)) "The app did not shut down cleanly."
    Assert-Portable ($appProcess.ExitCode -eq 0) "The portable executable returned an error on shutdown."
    Assert-Portable (@(Get-ChildItem -LiteralPath $testRoot -Force).Count -eq 1) "The app created unexpected companion files."
}
finally {
    if ($null -ne $appProcess) {
        if (-not $appProcess.HasExited) {
            if ($appWindow -ne [IntPtr]::Zero) {
                [void][PortableWindowTest]::Close($appWindow)
            }
            if (-not $appProcess.WaitForExit(3000)) {
                $appProcess.Kill()
                $appProcess.WaitForExit()
            }
        }
        $appProcess.Dispose()
    }
}

Write-Output "PASS: Embedded source, native serial class, split receive packet, address claim, UI tables, mode selection, capture clear, isolated EXE launch, UI timer, and clean shutdown."
Write-Output ("Isolated executable: {0}" -f $isolatedExecutable)
