[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ("..\.build\recording-tests-" + [Guid]::NewGuid().ToString("N"))))
[void][System.IO.Directory]::CreateDirectory($testRoot)

function Assert-Recording {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Wait-RecordingStopped {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($null -ne $Script:Recorder -and [DateTime]::UtcNow -lt $deadline) {
        Update-RecordingStatus
        Start-Sleep -Milliseconds 10
    }
    Assert-Recording ($null -eq $Script:Recorder) "The recording did not finish flushing."
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;

public sealed class RecordingTestPort : IDisposable
{
    public bool IsOpen { get; private set; }
    public int BytesToRead { get { return 0; } }
    public RecordingTestPort() { IsOpen = true; }
    public void Write(byte[] data, int offset, int count) { }
    public void Close() { IsOpen = false; }
    public void Dispose() { Close(); }
}

public sealed class RecordingFailureStream : MemoryStream
{
    private int writes;
    public override void Write(byte[] buffer, int offset, int count)
    {
        if (writes++ > 0)
        {
            throw new IOException("Synthetic disk write failure");
        }
        base.Write(buffer, offset, count);
    }
}

public sealed class RecordingBlockedStream : MemoryStream
{
    private int writes;
    public readonly ManualResetEvent Blocked = new ManualResetEvent(false);
    public readonly ManualResetEvent Release = new ManualResetEvent(false);
    public override void Write(byte[] buffer, int offset, int count)
    {
        if (writes++ > 0)
        {
            Blocked.Set();
            Release.WaitOne();
        }
        base.Write(buffer, offset, count);
    }
}
'@

$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\NMEA2000Diagnostics.ps1"))
$messageLoop = '[void][System.Windows.Forms.Application]::Run($form)'
Assert-Recording ($source.Contains($messageLoop)) "The application entry point could not be found."
$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

try {
    Invoke-Expression ($source.Replace($messageLoop, ""))
    $disconnectedPath = Join-Path $testRoot "disconnected.csv"
    Assert-Recording (-not (Start-Recording -Path $disconnectedPath)) "Recording started without an adapter connection."
    Assert-Recording (-not (Test-Path -LiteralPath $disconnectedPath)) "A disconnected attempt created a log file."

    $Script:SerialPort = New-Object RecordingTestPort
    $Script:CurrentPort = "COM_TEST"
    Set-ConnectionControls
    Assert-Recording $recordButton.Enabled "Record is disabled despite an open adapter."
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fr-FR")
    $Script:PgnNames[60928] = 'Address, "claim"'
    [byte[]]$claim = @(0xAA, 0xE8, 0x20, 0xFF, 0xEE, 0x18, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x55)

    Add-Frame -CanId 0x18EEFF20 -Extended $true -Remote $false -Data ([byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
    $csvPath = Join-Path $testRoot "traffic with spaces.csv"
    Assert-Recording (Start-Recording -Path $csvPath) "Recording could not start."
    $headerLength = (Get-Item -LiteralPath $csvPath).Length
    Assert-Recording (-not $recordButton.Enabled -and $stopRecordingButton.Enabled) "Recording controls did not change state."
    Assert-Recording (-not (Start-Recording -Path $csvPath -AllowOverwrite)) "A second recording was allowed to replace the active file."

    foreach ($value in $claim[0..5]) { $Script:RxBuffer.Add($value) }
    Parse-RxBuffer
    foreach ($value in $claim[6..14]) { $Script:RxBuffer.Add($value) }
    Parse-RxBuffer
    $activeRecorder = $Script:Recorder
    foreach ($value in $claim[0..5]) { $Script:RxBuffer.Add($value) }
    Parse-RxBuffer
    Clear-CapturedData
    Assert-Recording ([object]::ReferenceEquals($activeRecorder, $Script:Recorder)) "Clear Capture replaced the recorder."
    Assert-Recording (-not $Script:Recorder.IsStopping) "Clear Capture stopped the recording."
    Assert-Recording ($Script:RxBuffer.Count -eq 6) "Clear Capture discarded a partial packet during recording."
    foreach ($value in $claim[6..14]) { $Script:RxBuffer.Add($value) }
    Parse-RxBuffer

    $modeCombo.SelectedItem = "Normal"
    for ($index = 0; $index -lt 520; $index++) {
        Add-Frame -CanId 0x18F1122A -Extended $true -Remote $false -Data ([byte[]]@(0, 255, 170, 85))
    }
    Add-Frame -CanId 0x123 -Extended $false -Remote $true -Data ([byte[]]@())
    Update-Ui
    Assert-Recording ($Script:RawFrames.Count -eq 500) "The raw view's frame limit changed."
    $flushDeadline = [DateTime]::UtcNow.AddSeconds(4)
    while ((Get-Item -LiteralPath $csvPath).Length -le $headerLength -and [DateTime]::UtcNow -lt $flushDeadline) {
        Start-Sleep -Milliseconds 20
    }
    Assert-Recording ((Get-Item -LiteralPath $csvPath).Length -gt $headerLength) "Recording rows were not flushed while the session was active."

    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = [System.Drawing.Point]::new(-30000, -30000)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $form.PerformLayout()
    foreach ($size in @([System.Drawing.Size]::new(1240, 820), [System.Drawing.Size]::new(1100, 700))) {
        $form.Size = $size
        $form.PerformLayout()
        Assert-Recording ($recordingPanel.ClientRectangle.Contains($recordButton.Bounds)) "Record is clipped."
        Assert-Recording (-not $recordButton.Bounds.IntersectsWith($stopRecordingButton.Bounds)) "Recording buttons overlap."
        foreach ($statusLabel in $Script:StatusLabels.Values) {
            Assert-Recording ($statusPanel.ClientRectangle.Contains($statusLabel.Bounds)) "A bus status indicator is clipped."
        }
        $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        try {
            $form.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
            $bitmap.Save((Join-Path $testRoot ("recording-ui-{0}.png" -f $size.Width)), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose() }
    }

    Stop-Recording
    Wait-RecordingStopped
    $rows = @(Import-Csv -LiteralPath $csvPath)
    Assert-Recording ($rows.Count -eq 523 -and $Script:RecordingFrames -eq 523) "The recording was truncated by the raw-frame limit or Clear Capture."
    Assert-Recording ($rows[0].pgn -eq "60928" -and $rows[0].pgn_description -eq 'Address, "claim"') "PGN decoding or CSV escaping failed."
    Assert-Recording ($rows[0].can_id -eq "0x18EEFF20" -and $rows[0].data -eq "01 02 03 04 05 06 07 08") "CAN ID or raw data was changed in the log."
    Assert-Recording ($rows[0].mode -eq "Silent" -and $rows[2].mode -eq "Normal") "Mode changes were not preserved per frame."
    Assert-Recording ($rows[2].source -eq "42" -and $rows[2].pgn -eq "61714") "Source or PGN fields are incorrect."
    Assert-Recording ($rows[-1].frame_type -eq "standard" -and $rows[-1].remote -eq "1" -and $rows[-1].dlc -eq "0" -and $rows[-1].pgn -eq "") "Standard/remote frame fields are incorrect."
    Assert-Recording ($rows[0].timestamp_utc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') "The timestamp is not an unambiguous UTC ISO 8601 value."
    Assert-Recording ($rows[0].elapsed_seconds -match '^\d+\.\d{6}$') "Elapsed seconds depend on the user's locale."
    Assert-Recording ($rows[0].adapter_port -eq "COM_TEST" -and $rows[0].serial_baud -eq "2000000") "Adapter context is missing."
    $bytesBefore = [System.IO.File]::ReadAllBytes($csvPath)
    Add-Frame -CanId 0x18EEFF20 -Extended $true -Remote $false -Data ([byte[]]@(1))
    Assert-Recording ([System.IO.File]::ReadAllBytes($csvPath).Length -eq $bytesBefore.Length) "Frames were recorded after Stop."
    $exclusive = [System.IO.File]::Open($csvPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $exclusive.Dispose()

    Assert-Recording (-not (Start-Recording -Path $csvPath)) "An existing log was overwritten without approval."
    Assert-Recording ([System.IO.File]::ReadAllBytes($csvPath).Length -eq $bytesBefore.Length) "An existing log changed after a rejected start."
    Assert-Recording (-not (Start-Recording -Path (Join-Path $testRoot "missing\traffic.csv"))) "Recording started in a missing directory."
    Assert-Recording $Script:SerialPort.IsOpen "A file-open failure disconnected the adapter."

    $emptyPath = Join-Path $testRoot "empty.csv"
    Assert-Recording (Start-Recording -Path $emptyPath) "An empty recording could not start."
    Stop-Recording
    Wait-RecordingStopped
    Assert-Recording ((Get-Item -LiteralPath $emptyPath).Length -gt 0 -and @(Import-Csv -LiteralPath $emptyPath).Count -eq 0) "An empty recording is not a valid header-only CSV."
    Assert-Recording (Start-Recording -Path $emptyPath -AllowOverwrite) "A confirmed overwrite was rejected."
    Add-Frame -CanId 0x18EEFF20 -Extended $true -Remote $false -Data ([byte[]]@(1))
    foreach ($value in $claim[0..5]) { $Script:RxBuffer.Add($value) }
    Disconnect-Adapter
    Wait-RecordingStopped
    Assert-Recording (@(Import-Csv -LiteralPath $emptyPath).Count -eq 1 -and $null -eq $Script:SerialPort) "Disconnect did not flush and close the recording."
    Assert-Recording ($Script:RxBuffer.Count -eq 0) "A partial packet leaked across adapter connections."

    $Script:SerialPort = New-Object RecordingTestPort
    $header = @(New-RecordingRecord | ConvertTo-Csv -NoTypeInformation)[0]
    $Script:Recorder = New-Object CsvTrafficRecorder((New-Object RecordingFailureStream), [string]$header)
    $Script:RecordingStartedUtc = [DateTime]::UtcNow
    $Script:RecordingStoppedUtc = [DateTime]::MinValue
    $Script:RecordingError = ""
    Add-Frame -CanId 0x18EEFF20 -Extended $true -Remote $false -Data ([byte[]]@(1))
    Stop-Recording
    Wait-RecordingStopped
    Assert-Recording ($Script:RecordingError -like "*Synthetic disk write failure*") "An asynchronous disk-write failure was not reported."
    Assert-Recording ($Script:SerialPort.IsOpen -and $recordButton.Enabled) "A recording error prevented continued live capture or a new recording."

    $blockedStream = New-Object RecordingBlockedStream
    $overflowRecorder = New-Object CsvTrafficRecorder($blockedStream, [string]$header)
    try {
        $largeRow = 'x' * 1024
        for ($index = 0; $index -lt 1000; $index++) {
            Assert-Recording ($overflowRecorder.TryWrite($largeRow)) "The recorder failed before backpressure was applied."
        }
        Assert-Recording ($blockedStream.Blocked.WaitOne(3000)) "The simulated slow disk did not block the background writer."
        $accepted = 1000
        while ($accepted -lt 20000 -and $overflowRecorder.TryWrite($largeRow)) { $accepted++ }
        Assert-Recording ($overflowRecorder.IsStopping -and $overflowRecorder.Error -like "*queue is full*") "Queue overflow did not explicitly stop the recording."
        $blockedStream.Release.Set() | Out-Null
        $overflowRecorder.Dispose()
        Assert-Recording ($overflowRecorder.FramesWritten -eq $accepted) "Queued rows were not drained after overflow."
    }
    finally {
        [void]$blockedStream.Release.Set()
        $overflowRecorder.Dispose()
        $blockedStream.Blocked.Dispose()
        $blockedStream.Release.Dispose()
    }

    $closingPath = Join-Path $testRoot "closing.csv"
    Assert-Recording (Start-Recording -Path $closingPath) "Recording could not restart after a write failure."
    Add-Frame -CanId 0x18EEFF20 -Extended $true -Remote $false -Data ([byte[]]@(1, 2))
    $form.Close()
    Wait-RecordingStopped
    Assert-Recording (@(Import-Csv -LiteralPath $closingPath).Count -eq 1) "Closing the app did not flush the last frame."
    if (-not $form.IsDisposed) { Update-Ui }
    Assert-Recording $form.IsDisposed "The app window did not finish closing after the recording was saved."
}
finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    if ($null -ne $Script:Recorder) {
        $Script:Recorder.Dispose()
        $Script:Recorder = $null
    }
    if ($null -ne $form) {
        Disconnect-Adapter -Quiet
        $uiTimer.Stop()
        $uiTimer.Dispose()
        $pollTimer.Dispose()
        $recordingToolTip.Dispose()
        $form.Dispose()
    }
}

Write-Output "PASS: CSV timestamps/escaping/context, full capture beyond 500 frames, partial-packet clear, mode changes, periodic flush, stop/disconnect/close, overwrite protection, empty logs, disk failure recovery, queue overflow, and UI layout."
Write-Output ("Logs and UI renders: {0}" -f $testRoot)
