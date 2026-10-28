[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot "..\docs\screenshots"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[void][System.IO.Directory]::CreateDirectory($OutputDirectory)

Add-Type -TypeDefinition @'
using System;

public sealed class ReadmePreviewPort : IDisposable
{
    public bool IsOpen { get; private set; }
    public int BytesToRead { get { return 0; } }
    public ReadmePreviewPort() { IsOpen = true; }
    public void Write(byte[] buffer, int offset, int count) { }
    public void Close() { IsOpen = false; }
    public void Dispose() { Close(); }
}
'@

function New-PreviewCanId {
    param([int]$Pgn, [int]$Source, [int]$Priority = 6)
    $canId = [UInt32](($Priority -shl 26) -bor ($Pgn -shl 8) -bor $Source)
    if ((($Pgn -shr 8) -band 255) -lt 240) {
        $canId = $canId -bor [UInt32]0xFF00
    }
    return $canId
}

function Save-PreviewWindow {
    param([string]$FileName)
    $form.PerformLayout()
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    try {
        $form.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
        $bitmap.Save((Join-Path $OutputDirectory $FileName), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\NMEA2000Diagnostics.ps1"))
$messageLoop = '[void][System.Windows.Forms.Application]::Run($form)'
if (-not $source.Contains($messageLoop)) {
    throw "The application entry point could not be found."
}
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
    Invoke-Expression ($source.Replace($messageLoop, ""))
    $pollTimer.Stop()
    $uiTimer.Stop()
    $Script:SerialPort = New-Object ReadmePreviewPort
    $Script:CurrentPort = "COM3"
    $Script:CurrentMode = "Silent"
    $portCombo.Items.Clear()
    [void]$portCombo.Items.Add("COM3")
    $portCombo.SelectedItem = "COM3"
    Set-ConnectionControls

    $form.Size = [System.Drawing.Size]::new(1400, 980)
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = [System.Drawing.Point]::new(-30000, -30000)
    $form.Show()

    $previewDevices = @(
        @(3, 135, 120, 25, 20481),
        @(15, 1851, 130, 60, 31872),
        @(20, 1857, 145, 60, 24591),
        @(35, 275, 150, 40, 15744),
        @(44, 381, 130, 85, 42318),
        @(51, 419, 140, 60, 17652),
        @(64, 163, 140, 50, 85206),
        @(72, 273, 170, 35, 60934)
    )
    foreach ($device in $previewDevices) {
        $name = [UInt64]$device[4] -bor ([UInt64]$device[1] -shl 21) -bor ([UInt64]$device[2] -shl 40) -bor ([UInt64]$device[3] -shl 49) -bor ([UInt64]4 -shl 60) -bor ([UInt64]1 -shl 63)
        Add-Frame -CanId (New-PreviewCanId -Pgn 60928 -Source $device[0]) -Extended $true -Remote $false -Data ([BitConverter]::GetBytes($name))
    }

    # PGN, lifetime frame count, latest age in milliseconds, and observed sources.
    $traffic = @(
        @(60928, 8, 83400, @(3, 15, 20, 35, 44, 51, 64, 72)),
        @(126992, 1418, 382, @(20)),
        @(126993, 1332, 2410, @(3, 15, 20, 35, 44, 51, 64, 72)),
        @(126996, 160, 312000, @(3, 15, 20, 35, 44, 51, 64, 72)),
        @(127245, 12582, 84, @(35)),
        @(127250, 31452, 18, @(15, 35)),
        @(127251, 12588, 61, @(15)),
        @(127257, 18642, 43, @(15)),
        @(127258, 284, 14820, @(20)),
        @(127488, 27608, 37, @(64)),
        @(127489, 4223, 694, @(64)),
        @(127505, 2196, 1320, @(64, 72)),
        @(127506, 4184, 457, @(72)),
        @(127508, 8468, 174, @(72)),
        @(128259, 13304, 58, @(51)),
        @(128267, 13285, 129, @(51)),
        @(128275, 1380, 793, @(51)),
        @(129025, 26574, 12, @(20)),
        @(129026, 26592, 29, @(20)),
        @(129029, 21520, 246, @(20)),
        @(129539, 1390, 517, @(20)),
        @(129540, 4920, 1080, @(20)),
        @(130306, 14198, 34, @(44)),
        @(130310, 1420, 902, @(44, 51)),
        @(130312, 2784, 338, @(44, 51, 64)),
        @(130314, 1397, 723, @(44))
    )

    foreach ($entry in $traffic) {
        if (-not $Script:Pgns.ContainsKey([int]$entry[0])) {
            Add-Frame -CanId (New-PreviewCanId -Pgn $entry[0] -Source $entry[3][0]) -Extended $true -Remote $false -Data ([byte[]]@(0, 0, 255, 255, 255, 255, 255, 255))
        }
    }

    $random = New-Object System.Random(2406)
    $sceneAnchor = [DateTime]::UtcNow
    $recentFrames = New-Object System.Collections.ArrayList
    foreach ($entry in $traffic) {
        $interval = [Math]::Max(50.0, (1634000.0 / $entry[1]))
        for ($index = 0; ($entry[2] + ($index * $interval)) -lt 5000; $index++) {
            [byte[]]$data = @(($index % 253), 0, 0, 0, 0, 255, 255, 255)
            for ($byteIndex = 1; $byteIndex -lt 5; $byteIndex++) { $data[$byteIndex] = $random.Next(0, 256) }
            $address = $entry[3][$index % $entry[3].Count]
            Add-Frame -CanId (New-PreviewCanId -Pgn $entry[0] -Source $address) -Extended $true -Remote $false -Data $data
            $frame = $Script:RawFrames[0]
            $frame.Utc = $sceneAnchor.AddMilliseconds(-$entry[2] - ($index * $interval))
            [void]$recentFrames.Add($frame)
        }
    }

    $Script:RecordingStartedUtc = [DateTime]::UtcNow.AddSeconds(-273)
    $csv = @(New-RecordingRecord -Frame $Script:RawFrames[0] | ConvertTo-Csv -NoTypeInformation)
    $Script:Recorder = New-Object CsvTrafficRecorder((New-Object System.IO.MemoryStream), [string]$csv[0])
    for ($index = 0; $index -lt 54032; $index++) {
        if (-not $Script:Recorder.TryWrite([string]$csv[1])) { throw "The screenshot recorder stopped unexpectedly." }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($Script:Recorder.FramesWritten -lt 54032 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }

    $now = [DateTime]::UtcNow
    $Script:ConnectedUtc = $now.AddMinutes(-27).AddSeconds(-14)
    $Script:RecordingStartedUtc = $now.AddSeconds(-273)
    $Script:RecordingPath = 'C:\NMEA2000\Logs\NMEA2000-{0}.csv' -f $Script:RecordingStartedUtc.ToString("yyyyMMdd-HHmmss-fff'Z'")
    $Script:TotalFrames = 0
    foreach ($sourceRecord in $Script:Sources.Values) {
        $sourceRecord.Frames = 0
        $sourceRecord.LastUtc = [DateTime]::MinValue
    }
    foreach ($entry in $traffic) {
        $record = $Script:Pgns[[int]$entry[0]]
        $record.Count = $entry[1]
        $record.LastUtc = $now.AddMilliseconds(-$entry[2])
        $record.LastSource = $entry[3][0]
        $record.Sources.Clear()
        for ($sourceIndex = 0; $sourceIndex -lt $entry[3].Count; $sourceIndex++) {
            $address = $entry[3][$sourceIndex]
            $record.Sources[$address] = $record.LastUtc
            $sourceRecord = $Script:Sources[$address]
            $sourceRecord.Frames += [int][Math]::Floor($record.Count / $entry[3].Count)
            if ($sourceIndex -lt ($record.Count % $entry[3].Count)) { $sourceRecord.Frames++ }
            if ($record.LastUtc -gt $sourceRecord.LastUtc) {
                $sourceRecord.LastUtc = $record.LastUtc
                $sourceRecord.LastPgn = $record.Pgn
                $sourceRecord.LastPgnName = $record.Description
            }
        }
        $Script:TotalFrames += $record.Count
    }
    foreach ($frame in $recentFrames) {
        $frame.Utc = $now.AddMilliseconds(($frame.Utc - $sceneAnchor).TotalMilliseconds)
    }
    $Script:RawFrames.Clear()
    foreach ($frame in ($recentFrames | Sort-Object Utc -Descending | Select-Object -First 500)) { [void]$Script:RawFrames.Add($frame) }
    foreach ($device in $Script:Devices.Values) {
        $device.LastClaimUtc = $now.AddSeconds(-83.4 - ($device.Address - 3))
        $device.ClaimCount = 1
    }
    $Script:FrameWindow.Clear()
    foreach ($frame in $recentFrames) {
        $Script:FrameWindow.Enqueue([pscustomobject]@{ Time = $frame.Utc; Bits = 158 })
    }
    $Script:LastFrameUtc = $now.AddMilliseconds(-12)
    $Script:RxBuffer.Clear()
    Update-Ui
    Set-Footer "Connected to COM3 at 2000000 bps in Silent mode."

    foreach ($grid in @($pgnGrid, $deviceGrid, $sourceGrid, $rawGrid)) { $grid.ClearSelection() }
    $tabs.SelectedIndex = 0
    Save-PreviewWindow -FileName "overview.png"
    $tabs.SelectedIndex = 1
    Save-PreviewWindow -FileName "claimed-devices.png"
    $tabs.SelectedIndex = 3
    Save-PreviewWindow -FileName "raw-frames.png"

    Write-Output ("Rendered {0} PGNs, {1} devices, and {2:N0} total frames to {3}" -f $Script:Pgns.Count, $Script:Devices.Count, $Script:TotalFrames, $OutputDirectory)
}
finally {
    if ($null -ne $Script:Recorder) {
        $Script:Recorder.Dispose()
        $Script:Recorder = $null
    }
    if ($null -ne $form) {
        Disconnect-Adapter -Quiet
        $uiTimer.Dispose()
        $pollTimer.Dispose()
        $recordingToolTip.Dispose()
        $form.Dispose()
    }
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
}
