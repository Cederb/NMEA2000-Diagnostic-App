Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ("NativeSerialPort" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class NativeSerialPort : IDisposable
{
    private const UInt32 GENERIC_READ = 0x80000000;
    private const UInt32 GENERIC_WRITE = 0x40000000;
    private const UInt32 OPEN_EXISTING = 3;
    private const UInt32 PURGE_TXABORT = 0x0001;
    private const UInt32 PURGE_RXABORT = 0x0002;
    private const UInt32 PURGE_TXCLEAR = 0x0004;
    private const UInt32 PURGE_RXCLEAR = 0x0008;

    private IntPtr handle = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct DCB
    {
        public UInt32 DCBlength;
        public UInt32 BaudRate;
        public UInt32 Flags;
        public UInt16 wReserved;
        public UInt16 XonLim;
        public UInt16 XoffLim;
        public byte ByteSize;
        public byte Parity;
        public byte StopBits;
        public sbyte XonChar;
        public sbyte XoffChar;
        public sbyte ErrorChar;
        public sbyte EofChar;
        public sbyte EvtChar;
        public UInt16 wReserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct COMMTIMEOUTS
    {
        public UInt32 ReadIntervalTimeout;
        public UInt32 ReadTotalTimeoutMultiplier;
        public UInt32 ReadTotalTimeoutConstant;
        public UInt32 WriteTotalTimeoutMultiplier;
        public UInt32 WriteTotalTimeoutConstant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct COMSTAT
    {
        public UInt32 Flags;
        public UInt32 cbInQue;
        public UInt32 cbOutQue;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr CreateFile(
        string lpFileName,
        UInt32 dwDesiredAccess,
        UInt32 dwShareMode,
        IntPtr lpSecurityAttributes,
        UInt32 dwCreationDisposition,
        UInt32 dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetCommState(IntPtr hFile, ref DCB lpDCB);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetCommState(IntPtr hFile, ref DCB lpDCB);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetCommTimeouts(IntPtr hFile, ref COMMTIMEOUTS lpCommTimeouts);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, UInt32 nNumberOfBytesToRead, out UInt32 lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, UInt32 nNumberOfBytesToWrite, out UInt32 lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ClearCommError(IntPtr hFile, out UInt32 lpErrors, out COMSTAT lpStat);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PurgeComm(IntPtr hFile, UInt32 dwFlags);

    public bool IsOpen
    {
        get { return handle != new IntPtr(-1); }
    }

    public void Open(string portName, int baudRate)
    {
        if (IsOpen)
        {
            Close();
        }

        string deviceName = portName.StartsWith(@"\\.\") ? portName : @"\\.\" + portName;
        handle = CreateFile(deviceName, GENERIC_READ | GENERIC_WRITE, 0, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open " + portName);
        }

        try
        {
            DCB dcb = new DCB();
            dcb.DCBlength = (UInt32)Marshal.SizeOf(typeof(DCB));
            if (!GetCommState(handle, ref dcb))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read serial port state");
            }

            dcb.BaudRate = (UInt32)baudRate;
            dcb.ByteSize = 8;
            dcb.Parity = 0;
            dcb.StopBits = 0;
            dcb.Flags = 0x00000001 | 0x00000010 | 0x00001000;

            if (!SetCommState(handle, ref dcb))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure serial port state");
            }

            COMMTIMEOUTS timeouts = new COMMTIMEOUTS();
            timeouts.ReadIntervalTimeout = 1;
            timeouts.ReadTotalTimeoutMultiplier = 0;
            timeouts.ReadTotalTimeoutConstant = 1;
            timeouts.WriteTotalTimeoutMultiplier = 0;
            timeouts.WriteTotalTimeoutConstant = 500;
            if (!SetCommTimeouts(handle, ref timeouts))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure serial port timeouts");
            }

            DiscardBuffers();
        }
        catch
        {
            Close();
            throw;
        }
    }

    public int BytesToRead
    {
        get
        {
            EnsureOpen();
            UInt32 errors;
            COMSTAT stat;
            if (!ClearCommError(handle, out errors, out stat))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query serial receive queue");
            }
            return (int)stat.cbInQue;
        }
    }

    public int Read(byte[] buffer, int offset, int count)
    {
        EnsureOpen();
        if (offset != 0)
        {
            throw new ArgumentException("NativeSerialPort.Read currently requires offset 0.");
        }

        UInt32 read;
        if (!ReadFile(handle, buffer, (UInt32)count, out read, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Serial read failed");
        }
        return (int)read;
    }

    public void Write(byte[] buffer, int offset, int count)
    {
        EnsureOpen();
        byte[] writeBuffer = buffer;
        if (offset != 0 || count != buffer.Length)
        {
            writeBuffer = new byte[count];
            Array.Copy(buffer, offset, writeBuffer, 0, count);
        }

        UInt32 written;
        if (!WriteFile(handle, writeBuffer, (UInt32)count, out written, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Serial write failed");
        }

        if (written != count)
        {
            throw new InvalidOperationException("Serial write timed out before all bytes were sent.");
        }
    }

    public void DiscardBuffers()
    {
        EnsureOpen();
        if (!PurgeComm(handle, PURGE_RXABORT | PURGE_RXCLEAR | PURGE_TXABORT | PURGE_TXCLEAR))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not clear serial buffers");
        }
    }

    public void Close()
    {
        if (IsOpen)
        {
            CloseHandle(handle);
            handle = new IntPtr(-1);
        }
    }

    public void Dispose()
    {
        Close();
    }

    private void EnsureOpen()
    {
        if (!IsOpen)
        {
            throw new InvalidOperationException("Serial port is not open.");
        }
    }
}
"@
}

if (-not ("CsvTrafficRecorder" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public sealed class CsvTrafficRecorder : IDisposable
{
    private readonly BlockingCollection<string> pending = new BlockingCollection<string>(16384);
    private readonly StreamWriter writer;
    private readonly Thread worker;
    private volatile bool completed;
    private volatile string error;
    private long framesWritten;
    private bool disposed;

    public CsvTrafficRecorder(string path, string header, bool overwrite)
        : this(new FileStream(path, overwrite ? FileMode.Create : FileMode.CreateNew,
            FileAccess.Write, FileShare.Read, 65536, FileOptions.SequentialScan), header)
    {
    }

    public CsvTrafficRecorder(Stream output, string header)
    {
        try
        {
            writer = new StreamWriter(output, new UTF8Encoding(false), 65536);
            writer.NewLine = "\r\n";
            writer.WriteLine(header);
            writer.Flush();
            worker = new Thread(WriteLoop);
            worker.IsBackground = true;
            worker.Name = "NMEA2000 CSV recorder";
            worker.Start();
        }
        catch
        {
            try { output.Dispose(); } catch { }
            pending.Dispose();
            throw;
        }
    }

    public bool IsCompleted { get { return completed; } }
    public bool IsStopping { get { return pending.IsAddingCompleted; } }
    public string Error { get { return error; } }
    public long FramesWritten { get { return Interlocked.Read(ref framesWritten); } }

    public bool TryWrite(string row)
    {
        if (completed || pending.IsAddingCompleted)
        {
            return false;
        }

        try
        {
            if (pending.TryAdd(row))
            {
                return true;
            }
            StopWithError("The recording queue is full. Recording stopped; the log is incomplete.");
        }
        catch (InvalidOperationException)
        {
            // A disk error can stop the consumer while the UI is enqueueing a frame.
        }
        return false;
    }

    public void RequestStop()
    {
        pending.CompleteAdding();
    }

    public void StopWithError(string message)
    {
        if (error == null)
        {
            error = message;
        }
        RequestStop();
    }

    private void WriteLoop()
    {
        Stopwatch flushInterval = Stopwatch.StartNew();
        try
        {
            while (!pending.IsCompleted)
            {
                string row;
                if (pending.TryTake(out row, 200))
                {
                    writer.WriteLine(row);
                    Interlocked.Increment(ref framesWritten);
                }
                if (flushInterval.ElapsedMilliseconds >= 1000)
                {
                    writer.Flush();
                    flushInterval.Restart();
                }
            }
            writer.Flush();
        }
        catch (Exception exception)
        {
            StopWithError(exception.Message);
        }
        finally
        {
            try { writer.Dispose(); }
            catch (Exception exception) { StopWithError(exception.Message); }
            completed = true;
        }
    }

    public void Dispose()
    {
        if (!disposed)
        {
            RequestStop();
            worker.Join();
            pending.Dispose();
            disposed = true;
        }
    }
}
'@
}

$Script:SerialPort = $null
$Script:RxBuffer = New-Object 'System.Collections.Generic.List[byte]'
$Script:Pgns = @{}
$Script:Devices = @{}
$Script:Sources = @{}
$Script:RawFrames = New-Object System.Collections.ArrayList
$Script:FrameWindow = New-Object System.Collections.Queue
$Script:TotalFrames = 0
$Script:DecodeErrors = 0
$Script:LastFrameUtc = [DateTime]::MinValue
$Script:ConnectedUtc = [DateTime]::MinValue
$Script:CurrentMode = "Silent"
$Script:CurrentPort = ""
$Script:CurrentBaud = 2000000
$Script:MaxRawFrames = 500
$Script:Recorder = $null
$Script:RecordingPath = ""
$Script:RecordingStartedUtc = [DateTime]::MinValue
$Script:RecordingStoppedUtc = [DateTime]::MinValue
$Script:RecordingFrames = [long]0
$Script:RecordingError = ""
$Script:CloseAfterRecording = $false

$Script:PgnNames = @{
    59392  = "ISO Acknowledgement"
    59904  = "ISO Request"
    60160  = "ISO Transport Protocol - Data Transfer"
    60416  = "ISO Transport Protocol - Connection Management"
    60928  = "ISO Address Claim"
    61184  = "ISO Proprietary A"
    65240  = "ISO Commanded Address"
    126208 = "NMEA Request/Command/Acknowledge Group Function"
    126464 = "PGN List"
    126720 = "Proprietary Fast Packet"
    126992 = "System Time"
    126993 = "Heartbeat"
    126996 = "Product Information"
    126998 = "Configuration Information"
    127237 = "Heading/Track Control"
    127245 = "Rudder"
    127250 = "Vessel Heading"
    127251 = "Rate of Turn"
    127257 = "Attitude"
    127258 = "Magnetic Variation"
    127488 = "Engine Parameters - Rapid Update"
    127489 = "Engine Parameters - Dynamic"
    127493 = "Transmission Parameters - Dynamic"
    127497 = "Trip Parameters - Engine"
    127498 = "Engine Parameters - Static"
    127501 = "Binary Switch Bank Status"
    127502 = "Switch Bank Control"
    127505 = "Fluid Level"
    127506 = "DC Detailed Status"
    127507 = "Charger Status"
    127508 = "Battery Status"
    127509 = "Inverter Status"
    128000 = "Nautical Leeway"
    128259 = "Speed"
    128267 = "Water Depth"
    128275 = "Distance Log"
    129025 = "Position - Rapid Update"
    129026 = "COG & SOG - Rapid Update"
    129029 = "GNSS Position Data"
    129033 = "Time & Date"
    129038 = "AIS Class A Position Report"
    129039 = "AIS Class B Position Report"
    129040 = "AIS Class B Extended Position Report"
    129041 = "AIS Aids to Navigation"
    129044 = "Datum"
    129283 = "Cross Track Error"
    129284 = "Navigation Data"
    129285 = "Navigation Route/WP Information"
    129539 = "GNSS DOPs"
    129540 = "GNSS Satellites in View"
    129545 = "GNSS RAIM Output"
    129794 = "AIS Class A Static and Voyage Data"
    129798 = "AIS SAR Aircraft Position Report"
    129802 = "AIS Safety Related Broadcast"
    129808 = "DSC Call Information"
    129809 = "AIS Class B Static Data Part A"
    129810 = "AIS Class B Static Data Part B"
    130306 = "Wind Data"
    130310 = "Environmental Parameters"
    130311 = "Environmental Parameters"
    130312 = "Temperature"
    130313 = "Humidity"
    130314 = "Actual Pressure"
    130316 = "Temperature - Extended Range"
    130577 = "Direction Data"
    130578 = "Vessel Speed Components"
}

function Get-PgnName {
    param([int]$Pgn)

    if ($Script:PgnNames.ContainsKey($Pgn)) {
        return $Script:PgnNames[$Pgn]
    }

    return ""
}

function Format-Age {
    param([DateTime]$LastUtc)

    if ($LastUtc -eq [DateTime]::MinValue) {
        return "never"
    }

    $span = [DateTime]::UtcNow - $LastUtc
    $ms = [Math]::Max(0, $span.TotalMilliseconds)

    if ($ms -lt 1000) {
        return ("{0:N0} ms" -f $ms)
    }

    if ($span.TotalSeconds -lt 60) {
        return ("{0:N1} s" -f $span.TotalSeconds)
    }

    if ($span.TotalMinutes -lt 60) {
        return ("{0:N1} min" -f $span.TotalMinutes)
    }

    return ("{0:N1} h" -f $span.TotalHours)
}

function Format-LocalTime {
    param([DateTime]$Utc)

    if ($Utc -eq [DateTime]::MinValue) {
        return ""
    }

    return $Utc.ToLocalTime().ToString("HH:mm:ss.fff")
}

function ConvertTo-HexBytes {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }

    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join " ")
}

function ConvertFrom-NmeaCanId {
    param(
        [UInt32]$CanId,
        [bool]$Extended
    )

    if (-not $Extended) {
        return [pscustomobject]@{
            Priority = ""
            Pgn = $null
            PduFormat = ""
            PduSpecific = ""
            Source = ""
            Destination = ""
        }
    }

    $priority = [int](($CanId -shr 26) -band 0x07)
    $reserved = [int](($CanId -shr 25) -band 0x01)
    $dataPage = [int](($CanId -shr 24) -band 0x01)
    $pduFormat = [int](($CanId -shr 16) -band 0xFF)
    $pduSpecific = [int](($CanId -shr 8) -band 0xFF)
    $source = [int]($CanId -band 0xFF)

    if ($pduFormat -lt 240) {
        $pgn = ($reserved -shl 17) -bor ($dataPage -shl 16) -bor ($pduFormat -shl 8)
        $destination = $pduSpecific
    }
    else {
        $pgn = ($reserved -shl 17) -bor ($dataPage -shl 16) -bor ($pduFormat -shl 8) -bor $pduSpecific
        $destination = "global"
    }

    return [pscustomobject]@{
        Priority = $priority
        Pgn = [int]$pgn
        PduFormat = $pduFormat
        PduSpecific = $pduSpecific
        Source = $source
        Destination = $destination
    }
}

function ConvertFrom-NmeaName {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 8) {
        return $null
    }

    $nameBytes = New-Object byte[] 8
    [Array]::Copy($Bytes, 0, $nameBytes, 0, 8)
    $name = [BitConverter]::ToUInt64($nameBytes, 0)

    return [pscustomobject]@{
        NameHex = ("0x{0:X16}" -f $name)
        UniqueNumber = [int]($name -band 0x1FFFFF)
        ManufacturerCode = [int](($name -shr 21) -band 0x7FF)
        DeviceInstance = [int](($name -shr 32) -band 0x07)
        FunctionInstance = [int](($name -shr 35) -band 0x1F)
        DeviceFunction = [int](($name -shr 40) -band 0xFF)
        DeviceClass = [int](($name -shr 49) -band 0x7F)
        DeviceClassInstance = [int](($name -shr 56) -band 0x0F)
        IndustryGroup = [int](($name -shr 60) -band 0x07)
        ArbitraryAddressCapable = [bool](($name -shr 63) -band 0x01)
    }
}

function Estimate-CanFrameBits {
    param(
        [int]$Dlc,
        [bool]$Extended
    )

    $baseBits = 47
    if ($Extended) {
        $baseBits = 67
    }

    return [int][Math]::Ceiling(($baseBits + ($Dlc * 8)) * 1.2)
}

function New-WaveshareConfigPacket {
    param([string]$Mode)

    $packet = New-Object byte[] 20
    $packet[0] = 0xAA
    $packet[1] = 0x55
    $packet[2] = 0x12
    $packet[3] = 0x05
    $packet[4] = 0x02
    $packet[13] = 0x00
    if ($Mode -eq "Silent") {
        $packet[13] = 0x01
    }
    $packet[14] = 0x00

    $sum = 0
    for ($i = 2; $i -le 18; $i++) {
        $sum = ($sum + $packet[$i]) -band 0xFF
    }
    $packet[19] = [byte]$sum

    return $packet
}

function Send-AdapterConfiguration {
    if ($null -eq $Script:SerialPort -or -not $Script:SerialPort.IsOpen) {
        return
    }

    $mode = [string]$modeCombo.SelectedItem
    $packet = New-WaveshareConfigPacket -Mode $mode
    $Script:SerialPort.Write($packet, 0, $packet.Length)
    $Script:CurrentMode = $mode
}

function Set-Footer {
    param([string]$Text)

    $footerLabel.Text = $Text
    $recordingToolTip.SetToolTip($footerLabel, $Text)
}

function Set-StatusValue {
    param(
        [string]$Key,
        [string]$Value
    )

    if ($Script:StatusLabels.ContainsKey($Key)) {
        $Script:StatusLabels[$Key].Text = $Value
    }
}

function New-RecordingRecord {
    param([object]$Frame)

    $record = [ordered]@{
        timestamp_utc = ""
        elapsed_seconds = ""
        adapter_port = ""
        serial_baud = ""
        mode = ""
        can_id = ""
        frame_type = ""
        remote = ""
        priority = ""
        pgn = ""
        pgn_description = ""
        source = ""
        destination = ""
        dlc = ""
        data = ""
    }

    if ($null -ne $Frame) {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $record.timestamp_utc = $Frame.Utc.ToString("o", $culture)
        $record.elapsed_seconds = ($Frame.Utc - $Script:RecordingStartedUtc).TotalSeconds.ToString("F6", $culture)
        $record.adapter_port = $Script:CurrentPort
        $record.serial_baud = $Script:CurrentBaud.ToString($culture)
        $record.mode = $Script:CurrentMode
        $record.can_id = "0x{0:X8}" -f [UInt32]$Frame.Id
        $record.frame_type = $(if ($Frame.Extended) { "extended" } else { "standard" })
        $record.remote = [string][int]$Frame.Remote
        $record.priority = [string]$Frame.Priority
        $record.pgn = [string]$Frame.Pgn
        $record.pgn_description = [string]$Frame.PgnName
        $record.source = [string]$Frame.Source
        $record.destination = [string]$Frame.Destination
        $record.dlc = [string]$Frame.Length
        $record.data = [string]$Frame.Data
    }

    return [pscustomobject]$record
}

function Update-RecordingControls {
    $connected = ($null -ne $Script:SerialPort -and $Script:SerialPort.IsOpen)
    $recordButton.Enabled = $connected -and $null -eq $Script:Recorder -and -not $Script:CloseAfterRecording
    $stopRecordingButton.Enabled = ($null -ne $Script:Recorder -and -not $Script:Recorder.IsStopping -and -not $Script:Recorder.IsCompleted)
}

function Update-RecordingStatus {
    $state = "Not recording"
    if ($null -ne $Script:Recorder) {
        $Script:RecordingFrames = $Script:Recorder.FramesWritten
        if ($Script:Recorder.Error -and $Script:Recorder.Error -ne $Script:RecordingError) {
            $Script:RecordingError = $Script:Recorder.Error
            Set-Footer ("Recording error: {0} Live capture remains available." -f $Script:RecordingError)
        }
        if ($Script:Recorder.IsStopping -and $Script:RecordingStoppedUtc -eq [DateTime]::MinValue) {
            $Script:RecordingStoppedUtc = [DateTime]::UtcNow
        }
        if ($Script:Recorder.IsCompleted) {
            $Script:RecordingFrames = $Script:Recorder.FramesWritten
            $Script:RecordingError = [string]$Script:Recorder.Error
            $Script:Recorder.Dispose()
            $Script:Recorder = $null
            if ($Script:RecordingError) {
                Set-Footer ("Recording failed: {0} Partial log: {1}" -f $Script:RecordingError, $Script:RecordingPath)
            }
            else {
                Set-Footer ("Recording saved: {0:N0} frames to {1}" -f $Script:RecordingFrames, $Script:RecordingPath)
            }
        }
    }

    if ($null -ne $Script:Recorder) {
        $state = $(if ($Script:Recorder.IsStopping) { "Stopping" } else { "Recording" })
    }
    elseif ($Script:RecordingPath) {
        $state = $(if ($Script:RecordingError) { "Recording error" } else { "Saved" })
    }

    $duration = [TimeSpan]::Zero
    if ($Script:RecordingStartedUtc -ne [DateTime]::MinValue) {
        $end = $(if ($Script:RecordingStoppedUtc -eq [DateTime]::MinValue) { [DateTime]::UtcNow } else { $Script:RecordingStoppedUtc })
        $duration = $end - $Script:RecordingStartedUtc
    }
    $durationText = "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
    $recordingStatusLabel.Text = "{0} | {1:N0} frames | {2}" -f $state, $Script:RecordingFrames, $durationText
    $recordingStatusLabel.ForeColor = $(if ($state -eq "Recording" -or $Script:RecordingError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.SystemColors]::ControlText })
    $recordingPathLabel.Text = $Script:RecordingPath
    $recordingToolTip.SetToolTip($recordingPathLabel, $Script:RecordingPath)
    Update-RecordingControls
}

function Start-Recording {
    param(
        [string]$Path,
        [switch]$AllowOverwrite
    )

    if ($null -ne $Script:Recorder -or $Script:CloseAfterRecording) {
        Set-Footer "A recording is already active or still stopping."
        return $false
    }
    if ($null -eq $Script:SerialPort -or -not $Script:SerialPort.IsOpen) {
        Set-Footer "Connect to the adapter before starting a recording."
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw "Select a recording file."
        }
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $csv = @(New-RecordingRecord | ConvertTo-Csv -NoTypeInformation -Delimiter ',')
        $recorder = New-Object CsvTrafficRecorder($fullPath, [string]$csv[0], [bool]$AllowOverwrite)
        $Script:Recorder = $recorder
        $Script:RecordingPath = $fullPath
        $Script:RecordingStartedUtc = [DateTime]::UtcNow
        $Script:RecordingStoppedUtc = [DateTime]::MinValue
        $Script:RecordingFrames = [long]0
        $Script:RecordingError = ""
        Update-RecordingStatus
        Set-Footer ("Recording to {0}" -f $fullPath)
        return $true
    }
    catch {
        Set-Footer ("Could not start recording: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Select-RecordingFile {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Record NMEA2000 traffic"
    $dialog.Filter = "CSV traffic log (*.csv)|*.csv"
    $dialog.DefaultExt = "csv"
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.RestoreDirectory = $true
    $dialog.InitialDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $dialog.FileName = "NMEA2000-{0}.csv" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'")
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            [void](Start-Recording -Path $dialog.FileName -AllowOverwrite)
        }
    }
    finally {
        $dialog.Dispose()
    }
}

function Stop-Recording {
    if ($null -ne $Script:Recorder) {
        $Script:Recorder.RequestStop()
        if ($Script:RecordingStoppedUtc -eq [DateTime]::MinValue) {
            $Script:RecordingStoppedUtc = [DateTime]::UtcNow
        }
        Update-RecordingStatus
    }
}

function Write-RecordingFrame {
    param([object]$Frame)

    if ($null -eq $Script:Recorder -or $Script:Recorder.IsStopping -or $Script:Recorder.IsCompleted) {
        return
    }

    try {
        $csv = @(New-RecordingRecord -Frame $Frame | ConvertTo-Csv -NoTypeInformation -Delimiter ',')
        if (-not $Script:Recorder.TryWrite([string]$csv[1])) {
            Update-RecordingStatus
        }
    }
    catch {
        $Script:Recorder.StopWithError($_.Exception.Message)
        Update-RecordingStatus
    }
}

function Add-Frame {
    param(
        [UInt32]$CanId,
        [bool]$Extended,
        [bool]$Remote,
        [byte[]]$Data
    )

    $now = [DateTime]::UtcNow
    $Script:TotalFrames++
    $Script:LastFrameUtc = $now

    $bits = Estimate-CanFrameBits -Dlc $Data.Length -Extended $Extended
    [void]$Script:FrameWindow.Enqueue([pscustomobject]@{
        Time = $now
        Bits = $bits
    })

    $decoded = ConvertFrom-NmeaCanId -CanId $CanId -Extended $Extended
    $pgn = $decoded.Pgn
    $pgnName = ""

    if ($null -ne $pgn) {
        $pgnName = Get-PgnName -Pgn $pgn
        if (-not $Script:Pgns.ContainsKey($pgn)) {
            $Script:Pgns[$pgn] = [pscustomobject]@{
                Pgn = $pgn
                Description = $pgnName
                Count = 0
                LastUtc = [DateTime]::MinValue
                LastSource = ""
                LastLength = 0
                Sources = @{}
            }
        }

        $pgnRecord = $Script:Pgns[$pgn]
        $pgnRecord.Count++
        $pgnRecord.LastUtc = $now
        $pgnRecord.LastSource = $decoded.Source
        $pgnRecord.LastLength = $Data.Length
        $pgnRecord.Sources[$decoded.Source] = $now

        if (-not $Script:Sources.ContainsKey($decoded.Source)) {
            $Script:Sources[$decoded.Source] = [pscustomobject]@{
                Source = $decoded.Source
                Frames = 0
                LastPgn = ""
                LastPgnName = ""
                LastUtc = [DateTime]::MinValue
                ClaimedName = ""
            }
        }

        $sourceRecord = $Script:Sources[$decoded.Source]
        $sourceRecord.Frames++
        $sourceRecord.LastPgn = $pgn
        $sourceRecord.LastPgnName = $pgnName
        $sourceRecord.LastUtc = $now

        if ($pgn -eq 60928 -and $Data.Length -ge 8) {
            $nameInfo = ConvertFrom-NmeaName -Bytes $Data
            if ($null -ne $nameInfo) {
                if (-not $Script:Devices.ContainsKey($decoded.Source)) {
                    $Script:Devices[$decoded.Source] = [pscustomobject]@{
                        Address = $decoded.Source
                        NameHex = ""
                        ManufacturerCode = ""
                        DeviceClass = ""
                        DeviceFunction = ""
                        IndustryGroup = ""
                        UniqueNumber = ""
                        DeviceInstance = ""
                        FunctionInstance = ""
                        LastClaimUtc = [DateTime]::MinValue
                        ClaimCount = 0
                    }
                }

                $device = $Script:Devices[$decoded.Source]
                $device.NameHex = $nameInfo.NameHex
                $device.ManufacturerCode = $nameInfo.ManufacturerCode
                $device.DeviceClass = $nameInfo.DeviceClass
                $device.DeviceFunction = $nameInfo.DeviceFunction
                $device.IndustryGroup = $nameInfo.IndustryGroup
                $device.UniqueNumber = $nameInfo.UniqueNumber
                $device.DeviceInstance = $nameInfo.DeviceInstance
                $device.FunctionInstance = $nameInfo.FunctionInstance
                $device.LastClaimUtc = $now
                $device.ClaimCount++
                $sourceRecord.ClaimedName = $nameInfo.NameHex
            }
        }
    }

    $frame = [pscustomobject]@{
        Utc = $now
        Id = $CanId
        Extended = $Extended
        Remote = $Remote
        Pgn = $pgn
        PgnName = $pgnName
        Source = $decoded.Source
        Destination = $decoded.Destination
        Priority = $decoded.Priority
        Length = $Data.Length
        Data = ConvertTo-HexBytes -Bytes $Data
    }
    Write-RecordingFrame -Frame $frame
    [void]$Script:RawFrames.Insert(0, $frame)

    while ($Script:RawFrames.Count -gt $Script:MaxRawFrames) {
        $Script:RawFrames.RemoveAt($Script:RawFrames.Count - 1)
    }
}

function Parse-RxBuffer {
    while ($Script:RxBuffer.Count -gt 0) {
        $start = $Script:RxBuffer.IndexOf([byte]0xAA)
        if ($start -lt 0) {
            $Script:RxBuffer.Clear()
            return
        }

        if ($start -gt 0) {
            $Script:RxBuffer.RemoveRange(0, $start)
        }

        if ($Script:RxBuffer.Count -lt 3) {
            return
        }

        $type = [byte]$Script:RxBuffer[1]
        if (($type -band 0xC0) -ne 0xC0) {
            $Script:DecodeErrors++
            $Script:RxBuffer.RemoveAt(0)
            continue
        }

        $dlc = [int]($type -band 0x0F)
        if ($dlc -gt 8) {
            $Script:DecodeErrors++
            $Script:RxBuffer.RemoveAt(0)
            continue
        }

        $extended = (($type -band 0x20) -ne 0)
        $remote = (($type -band 0x10) -ne 0)
        $idLength = 2
        if ($extended) {
            $idLength = 4
        }

        $packetLength = 1 + 1 + $idLength + $dlc + 1
        if ($Script:RxBuffer.Count -lt $packetLength) {
            return
        }

        if ([byte]$Script:RxBuffer[$packetLength - 1] -ne [byte]0x55) {
            $Script:DecodeErrors++
            $Script:RxBuffer.RemoveAt(0)
            continue
        }

        $canId = [UInt32]0
        for ($i = 0; $i -lt $idLength; $i++) {
            $canId = $canId -bor ([UInt32]$Script:RxBuffer[2 + $i] -shl (8 * $i))
        }

        $data = New-Object byte[] $dlc
        for ($i = 0; $i -lt $dlc; $i++) {
            $data[$i] = [byte]$Script:RxBuffer[2 + $idLength + $i]
        }

        $Script:RxBuffer.RemoveRange(0, $packetLength)
        Add-Frame -CanId $canId -Extended $extended -Remote $remote -Data $data
    }
}

function Poll-Serial {
    if ($null -eq $Script:SerialPort -or -not $Script:SerialPort.IsOpen) {
        return
    }

    try {
        $available = $Script:SerialPort.BytesToRead
        if ($available -le 0) {
            return
        }

        $buffer = New-Object byte[] $available
        $read = $Script:SerialPort.Read($buffer, 0, $available)
        for ($i = 0; $i -lt $read; $i++) {
            $Script:RxBuffer.Add($buffer[$i])
        }

        Parse-RxBuffer
    }
    catch {
        Set-Footer ("Serial read failed: {0}" -f $_.Exception.Message)
        Disconnect-Adapter
    }
}

function Clear-CapturedData {
    if ($null -eq $Script:Recorder) {
        $Script:RxBuffer.Clear()
    }
    $Script:Pgns.Clear()
    $Script:Devices.Clear()
    $Script:Sources.Clear()
    $Script:RawFrames.Clear()
    $Script:FrameWindow.Clear()
    $Script:TotalFrames = 0
    $Script:DecodeErrors = 0
    $Script:LastFrameUtc = [DateTime]::MinValue
    Update-Ui
    Set-Footer "Captured data cleared."
}

function Refresh-Ports {
    $previous = [string]$portCombo.SelectedItem
    $portCombo.Items.Clear()
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object

    foreach ($port in $ports) {
        [void]$portCombo.Items.Add($port)
    }

    if ($ports -contains $previous) {
        $portCombo.SelectedItem = $previous
    }
    elseif ($portCombo.Items.Count -gt 0) {
        $portCombo.SelectedIndex = 0
    }
}

function Set-ConnectionControls {
    $connected = ($null -ne $Script:SerialPort -and $Script:SerialPort.IsOpen)
    $connectButton.Enabled = -not $connected
    $disconnectButton.Enabled = $connected
    $portCombo.Enabled = -not $connected
    $baudCombo.Enabled = -not $connected
    $refreshPortsButton.Enabled = -not $connected
    Update-RecordingControls
}

function Connect-Adapter {
    if ($null -eq $portCombo.SelectedItem -or [string]::IsNullOrWhiteSpace([string]$portCombo.SelectedItem)) {
        Set-Footer "Select a COM port before connecting."
        return
    }

    try {
        Disconnect-Adapter -Quiet

        $Script:CurrentPort = [string]$portCombo.SelectedItem
        $Script:CurrentBaud = [int][string]$baudCombo.SelectedItem
        $Script:CurrentMode = [string]$modeCombo.SelectedItem

        $port = New-Object NativeSerialPort
        $port.Open($Script:CurrentPort, $Script:CurrentBaud)

        Start-Sleep -Milliseconds 100
        $port.DiscardBuffers()

        $Script:SerialPort = $port
        $Script:ConnectedUtc = [DateTime]::UtcNow
        Send-AdapterConfiguration
        $pollTimer.Start()
        Set-ConnectionControls
        Set-Footer ("Connected to {0} at {1} bps in {2} mode." -f $Script:CurrentPort, $Script:CurrentBaud, $Script:CurrentMode)
    }
    catch {
        Set-Footer ("Connect failed: {0}" -f $_.Exception.Message)
        if ($null -ne $Script:SerialPort) {
            try {
                $Script:SerialPort.Close()
                $Script:SerialPort.Dispose()
            }
            catch {
            }
        }
        $Script:SerialPort = $null
        Set-ConnectionControls
    }
}

function Disconnect-Adapter {
    param([switch]$Quiet)

    $pollTimer.Stop()
    Stop-Recording
    $Script:RxBuffer.Clear()

    if ($null -ne $Script:SerialPort) {
        try {
            if ($Script:SerialPort.IsOpen) {
                $Script:SerialPort.Close()
            }
            $Script:SerialPort.Dispose()
        }
        catch {
            if (-not $Quiet) {
                Set-Footer ("Disconnect warning: {0}" -f $_.Exception.Message)
            }
        }
    }

    $Script:SerialPort = $null
    $Script:ConnectedUtc = [DateTime]::MinValue
    Set-ConnectionControls

    if (-not $Quiet) {
        Set-Footer "Disconnected."
    }
}

function Update-GridRows {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [object[]]$Rows
    )

    $Grid.SuspendLayout()
    $Grid.Rows.Clear()
    foreach ($row in $Rows) {
        [void]$Grid.Rows.Add($row)
    }
    $Grid.ResumeLayout()
}

function Update-Ui {
    Update-RecordingStatus
    if ($Script:CloseAfterRecording -and $null -eq $Script:Recorder) {
        $Script:CloseAfterRecording = $false
        if ($Script:RecordingError) {
            [void][System.Windows.Forms.MessageBox]::Show($form, ("Recording failed: {0}`r`nPartial log: {1}" -f $Script:RecordingError, $Script:RecordingPath), "Recording error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        $form.Close()
        return
    }
    $now = [DateTime]::UtcNow

    while ($Script:FrameWindow.Count -gt 0) {
        $oldest = $Script:FrameWindow.Peek()
        if (($now - $oldest.Time).TotalSeconds -le 5) {
            break
        }
        [void]$Script:FrameWindow.Dequeue()
    }

    $windowSeconds = 5.0
    if ($Script:ConnectedUtc -ne [DateTime]::MinValue) {
        $elapsed = [Math]::Max(0.1, ($now - $Script:ConnectedUtc).TotalSeconds)
        $windowSeconds = [Math]::Min(5.0, $elapsed)
    }

    $windowBits = 0
    foreach ($item in $Script:FrameWindow) {
        $windowBits += [int]$item.Bits
    }

    $framesPerSecond = $Script:FrameWindow.Count / $windowSeconds
    $busLoad = ($windowBits / $windowSeconds) / 250000.0 * 100.0
    $connected = ($null -ne $Script:SerialPort -and $Script:SerialPort.IsOpen)

    Set-StatusValue -Key "Connection" -Value $(if ($connected) { "Connected" } else { "Disconnected" })
    Set-StatusValue -Key "Port" -Value $(if ($connected) { $Script:CurrentPort } else { "" })
    Set-StatusValue -Key "Mode" -Value $Script:CurrentMode
    Set-StatusValue -Key "SerialBaud" -Value ("{0:N0} bps" -f $Script:CurrentBaud)
    Set-StatusValue -Key "CanRate" -Value "250 kbit/s"
    Set-StatusValue -Key "TotalFrames" -Value ("{0:N0}" -f $Script:TotalFrames)
    Set-StatusValue -Key "FramesPerSecond" -Value ("{0:N1}" -f $framesPerSecond)
    Set-StatusValue -Key "BusLoad" -Value ("{0:N2}%" -f $busLoad)
    Set-StatusValue -Key "UniquePgns" -Value ("{0:N0}" -f $Script:Pgns.Count)
    Set-StatusValue -Key "ActiveSources" -Value ("{0:N0}" -f $Script:Sources.Count)
    Set-StatusValue -Key "ClaimedDevices" -Value ("{0:N0}" -f $Script:Devices.Count)
    Set-StatusValue -Key "LastFrameAge" -Value (Format-Age -LastUtc $Script:LastFrameUtc)
    Set-StatusValue -Key "DecodeErrors" -Value ("{0:N0}" -f $Script:DecodeErrors)
    Set-StatusValue -Key "BufferedBytes" -Value ("{0:N0}" -f $Script:RxBuffer.Count)

    $pgnRows = @()
    foreach ($key in ($Script:Pgns.Keys | Sort-Object { [int]$_ })) {
        $record = $Script:Pgns[$key]
        $sources = (($record.Sources.Keys | Sort-Object { [int]$_ }) | ForEach-Object { [string]$_ }) -join ", "
        $pgnRows += ,@(
            [string]$record.Pgn,
            ("0x{0:X5}" -f [int]$record.Pgn),
            [string]$record.Description,
            ("{0:N0}" -f $record.Count),
            (Format-Age -LastUtc $record.LastUtc),
            (Format-LocalTime -Utc $record.LastUtc),
            $sources,
            [string]$record.LastSource,
            [string]$record.LastLength
        )
    }
    Update-GridRows -Grid $pgnGrid -Rows $pgnRows

    $deviceRows = @()
    foreach ($key in ($Script:Devices.Keys | Sort-Object { [int]$_ })) {
        $device = $Script:Devices[$key]
        $deviceRows += ,@(
            [string]$device.Address,
            [string]$device.NameHex,
            [string]$device.ManufacturerCode,
            [string]$device.DeviceClass,
            [string]$device.DeviceFunction,
            [string]$device.IndustryGroup,
            [string]$device.UniqueNumber,
            [string]$device.DeviceInstance,
            [string]$device.FunctionInstance,
            (Format-Age -LastUtc $device.LastClaimUtc),
            ("{0:N0}" -f $device.ClaimCount)
        )
    }
    Update-GridRows -Grid $deviceGrid -Rows $deviceRows

    $sourceRows = @()
    foreach ($key in ($Script:Sources.Keys | Sort-Object { [int]$_ })) {
        $source = $Script:Sources[$key]
        $sourceRows += ,@(
            [string]$source.Source,
            [string]$source.ClaimedName,
            ("{0:N0}" -f $source.Frames),
            [string]$source.LastPgn,
            [string]$source.LastPgnName,
            (Format-Age -LastUtc $source.LastUtc),
            (Format-LocalTime -Utc $source.LastUtc)
        )
    }
    Update-GridRows -Grid $sourceGrid -Rows $sourceRows

    $rawRows = @()
    foreach ($frame in $Script:RawFrames) {
        $rawRows += ,@(
            (Format-LocalTime -Utc $frame.Utc),
            (Format-Age -LastUtc $frame.Utc),
            ("0x{0:X8}" -f [UInt32]$frame.Id),
            $(if ($frame.Extended) { "ext" } else { "std" }),
            [string]$frame.Priority,
            [string]$frame.Pgn,
            [string]$frame.PgnName,
            [string]$frame.Source,
            [string]$frame.Destination,
            [string]$frame.Length,
            [string]$frame.Data
        )
    }
    Update-GridRows -Grid $rawGrid -Rows $rawRows
}

function Add-GridColumn {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Name,
        [string]$HeaderText,
        [int]$FillWeight
    )

    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.HeaderText = $HeaderText
    $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $column.FillWeight = $FillWeight
    [void]$Grid.Columns.Add($column)
}

function New-Grid {
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.ReadOnly = $true
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    return $grid
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "NMEA2000 Bus Diagnostics - Waveshare USB-CAN-A"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(1100, 700)
$form.Size = New-Object System.Drawing.Size(1240, 820)

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.ColumnCount = 1
$root.RowCount = 5
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
$form.Controls.Add($root)

$controlsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$controlsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$controlsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$controlsPanel.WrapContents = $false
$controlsPanel.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 8)
$controlsPanel.AutoScroll = $true
$root.Controls.Add($controlsPanel, 0, 0)

$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = "Port"
$portLabel.AutoSize = $true
$portLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 6, 0)
$controlsPanel.Controls.Add($portLabel)

$portCombo = New-Object System.Windows.Forms.ComboBox
$portCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$portCombo.Width = 90
$controlsPanel.Controls.Add($portCombo)

$refreshPortsButton = New-Object System.Windows.Forms.Button
$refreshPortsButton.Text = "Refresh"
$refreshPortsButton.Width = 78
$controlsPanel.Controls.Add($refreshPortsButton)

$baudLabel = New-Object System.Windows.Forms.Label
$baudLabel.Text = "Adapter baud"
$baudLabel.AutoSize = $true
$baudLabel.Margin = New-Object System.Windows.Forms.Padding(16, 7, 6, 0)
$controlsPanel.Controls.Add($baudLabel)

$baudCombo = New-Object System.Windows.Forms.ComboBox
$baudCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$baudCombo.Width = 105
foreach ($baud in @(2000000, 1228800, 115200, 38400, 19200, 9600)) {
    [void]$baudCombo.Items.Add([string]$baud)
}
$baudCombo.SelectedItem = "2000000"
$controlsPanel.Controls.Add($baudCombo)

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "Mode"
$modeLabel.AutoSize = $true
$modeLabel.Margin = New-Object System.Windows.Forms.Padding(16, 7, 6, 0)
$controlsPanel.Controls.Add($modeLabel)

$modeCombo = New-Object System.Windows.Forms.ComboBox
$modeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$modeCombo.Width = 94
[void]$modeCombo.Items.Add("Silent")
[void]$modeCombo.Items.Add("Normal")
$modeCombo.SelectedItem = "Silent"
$controlsPanel.Controls.Add($modeCombo)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Text = "Connect"
$connectButton.Width = 88
$connectButton.Margin = New-Object System.Windows.Forms.Padding(18, 3, 3, 3)
$controlsPanel.Controls.Add($connectButton)

$disconnectButton = New-Object System.Windows.Forms.Button
$disconnectButton.Text = "Disconnect"
$disconnectButton.Width = 94
$disconnectButton.Enabled = $false
$controlsPanel.Controls.Add($disconnectButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear Capture"
$clearButton.Width = 104
$clearButton.Margin = New-Object System.Windows.Forms.Padding(18, 3, 3, 3)
$controlsPanel.Controls.Add($clearButton)

$recordingPanel = New-Object System.Windows.Forms.TableLayoutPanel
$recordingPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$recordingPanel.ColumnCount = 4
$recordingPanel.RowCount = 1
$recordingPanel.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 4)
[void]$recordingPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 104)))
[void]$recordingPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
[void]$recordingPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300)))
[void]$recordingPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$root.Controls.Add($recordingPanel, 0, 1)

$recordButton = New-Object System.Windows.Forms.Button
$recordButton.Text = "Record..."
$recordButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$recordButton.Enabled = $false
$recordingPanel.Controls.Add($recordButton, 0, 0)

$stopRecordingButton = New-Object System.Windows.Forms.Button
$stopRecordingButton.Text = "Stop"
$stopRecordingButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$stopRecordingButton.Enabled = $false
$recordingPanel.Controls.Add($stopRecordingButton, 1, 0)

$recordingStatusLabel = New-Object System.Windows.Forms.Label
$recordingStatusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$recordingStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$recordingStatusLabel.AutoEllipsis = $true
$recordingPanel.Controls.Add($recordingStatusLabel, 2, 0)

$recordingPathLabel = New-Object System.Windows.Forms.Label
$recordingPathLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$recordingPathLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$recordingPathLabel.AutoEllipsis = $true
$recordingPanel.Controls.Add($recordingPathLabel, 3, 0)
$recordingToolTip = New-Object System.Windows.Forms.ToolTip

$statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusPanel.ColumnCount = 4
$statusPanel.RowCount = 7
for ($rowIndex = 0; $rowIndex -lt 7; $rowIndex++) {
    [void]$statusPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, (100.0 / 7))))
}
$statusPanel.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 8)
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 138)))
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 138)))
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$root.Controls.Add($statusPanel, 0, 2)

$Script:StatusLabels = @{}
$statusItems = @(
    @("Connection", "Connection"), @("Port", "Port"),
    @("Mode", "Mode"), @("Serial baud", "SerialBaud"),
    @("CAN rate", "CanRate"), @("Total frames", "TotalFrames"),
    @("Frames/s", "FramesPerSecond"), @("Bus load est.", "BusLoad"),
    @("Unique PGNs", "UniquePgns"), @("Active sources", "ActiveSources"),
    @("Claimed devices", "ClaimedDevices"), @("Last frame age", "LastFrameAge"),
    @("Decode errors", "DecodeErrors"), @("Buffered bytes", "BufferedBytes")
)

for ($i = 0; $i -lt $statusItems.Count; $i++) {
    $row = [Math]::Floor($i / 2)
    $column = ($i % 2) * 2
    $labelText = $statusItems[$i][0]
    $key = $statusItems[$i][1]

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $labelText
    $nameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $nameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nameLabel.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = ""
    $valueLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $valueLabel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $statusPanel.Controls.Add($nameLabel, $column, $row)
    $statusPanel.Controls.Add($valueLabel, $column + 1, $row)
    $Script:StatusLabels[$key] = $valueLabel
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.Controls.Add($tabs, 0, 3)

$pgnTab = New-Object System.Windows.Forms.TabPage
$pgnTab.Text = "Unique PGNs"
$tabs.Controls.Add($pgnTab)
$pgnGrid = New-Grid
Add-GridColumn -Grid $pgnGrid -Name "Pgn" -HeaderText "PGN" -FillWeight 70
Add-GridColumn -Grid $pgnGrid -Name "Hex" -HeaderText "Hex" -FillWeight 70
Add-GridColumn -Grid $pgnGrid -Name "Description" -HeaderText "Description" -FillWeight 210
Add-GridColumn -Grid $pgnGrid -Name "Frames" -HeaderText "Frames" -FillWeight 70
Add-GridColumn -Grid $pgnGrid -Name "Age" -HeaderText "Latest age" -FillWeight 80
Add-GridColumn -Grid $pgnGrid -Name "Time" -HeaderText "Latest time" -FillWeight 90
Add-GridColumn -Grid $pgnGrid -Name "Sources" -HeaderText "Sources" -FillWeight 160
Add-GridColumn -Grid $pgnGrid -Name "LastSource" -HeaderText "Last source" -FillWeight 75
Add-GridColumn -Grid $pgnGrid -Name "Length" -HeaderText "Len" -FillWeight 45
$pgnTab.Controls.Add($pgnGrid)

$deviceTab = New-Object System.Windows.Forms.TabPage
$deviceTab.Text = "Claimed Devices"
$tabs.Controls.Add($deviceTab)
$deviceGrid = New-Grid
Add-GridColumn -Grid $deviceGrid -Name "Address" -HeaderText "Address" -FillWeight 60
Add-GridColumn -Grid $deviceGrid -Name "Name" -HeaderText "NAME" -FillWeight 160
Add-GridColumn -Grid $deviceGrid -Name "Manufacturer" -HeaderText "Manufacturer code" -FillWeight 105
Add-GridColumn -Grid $deviceGrid -Name "Class" -HeaderText "Device class" -FillWeight 85
Add-GridColumn -Grid $deviceGrid -Name "Function" -HeaderText "Function" -FillWeight 70
Add-GridColumn -Grid $deviceGrid -Name "Industry" -HeaderText "Industry" -FillWeight 60
Add-GridColumn -Grid $deviceGrid -Name "Unique" -HeaderText "Unique no." -FillWeight 80
Add-GridColumn -Grid $deviceGrid -Name "DeviceInstance" -HeaderText "Dev inst." -FillWeight 60
Add-GridColumn -Grid $deviceGrid -Name "FunctionInstance" -HeaderText "Func inst." -FillWeight 65
Add-GridColumn -Grid $deviceGrid -Name "Age" -HeaderText "Claim age" -FillWeight 75
Add-GridColumn -Grid $deviceGrid -Name "Claims" -HeaderText "Claims" -FillWeight 55
$deviceTab.Controls.Add($deviceGrid)

$sourceTab = New-Object System.Windows.Forms.TabPage
$sourceTab.Text = "Source Addresses"
$tabs.Controls.Add($sourceTab)
$sourceGrid = New-Grid
Add-GridColumn -Grid $sourceGrid -Name "Source" -HeaderText "Source" -FillWeight 60
Add-GridColumn -Grid $sourceGrid -Name "ClaimedName" -HeaderText "Claimed NAME" -FillWeight 160
Add-GridColumn -Grid $sourceGrid -Name "Frames" -HeaderText "Frames" -FillWeight 70
Add-GridColumn -Grid $sourceGrid -Name "LastPgn" -HeaderText "Last PGN" -FillWeight 75
Add-GridColumn -Grid $sourceGrid -Name "LastPgnName" -HeaderText "Last PGN description" -FillWeight 220
Add-GridColumn -Grid $sourceGrid -Name "Age" -HeaderText "Latest age" -FillWeight 80
Add-GridColumn -Grid $sourceGrid -Name "Time" -HeaderText "Latest time" -FillWeight 90
$sourceTab.Controls.Add($sourceGrid)

$rawTab = New-Object System.Windows.Forms.TabPage
$rawTab.Text = "Raw Frames"
$tabs.Controls.Add($rawTab)
$rawGrid = New-Grid
Add-GridColumn -Grid $rawGrid -Name "Time" -HeaderText "Time" -FillWeight 90
Add-GridColumn -Grid $rawGrid -Name "Age" -HeaderText "Age" -FillWeight 80
Add-GridColumn -Grid $rawGrid -Name "Id" -HeaderText "CAN ID" -FillWeight 95
Add-GridColumn -Grid $rawGrid -Name "Type" -HeaderText "Type" -FillWeight 50
Add-GridColumn -Grid $rawGrid -Name "Priority" -HeaderText "Prio" -FillWeight 45
Add-GridColumn -Grid $rawGrid -Name "Pgn" -HeaderText "PGN" -FillWeight 70
Add-GridColumn -Grid $rawGrid -Name "Description" -HeaderText "Description" -FillWeight 210
Add-GridColumn -Grid $rawGrid -Name "Source" -HeaderText "Src" -FillWeight 45
Add-GridColumn -Grid $rawGrid -Name "Destination" -HeaderText "Dst" -FillWeight 60
Add-GridColumn -Grid $rawGrid -Name "Length" -HeaderText "Len" -FillWeight 45
Add-GridColumn -Grid $rawGrid -Name "Data" -HeaderText "Data" -FillWeight 180
$rawTab.Controls.Add($rawGrid)

$footerPanel = New-Object System.Windows.Forms.Panel
$footerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$footerPanel.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 0)
$root.Controls.Add($footerPanel, 0, 4)

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$footerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$footerLabel.AutoEllipsis = $true
$footerLabel.Text = "Select the Waveshare COM port, choose mode, then connect."
$footerPanel.Controls.Add($footerLabel)

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 40
$pollTimer.Add_Tick({ Poll-Serial })

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 1000
$uiTimer.Add_Tick({ Update-Ui })
$uiTimer.Start()

$refreshPortsButton.Add_Click({ Refresh-Ports })
$connectButton.Add_Click({ Connect-Adapter })
$disconnectButton.Add_Click({ Disconnect-Adapter })
$clearButton.Add_Click({ Clear-CapturedData })
$recordButton.Add_Click({ Select-RecordingFile })
$stopRecordingButton.Add_Click({ Stop-Recording })
$modeCombo.Add_SelectedIndexChanged({
    if ($null -ne $Script:SerialPort -and $Script:SerialPort.IsOpen) {
        try {
            Send-AdapterConfiguration
            Set-Footer ("Mode changed to {0}." -f $Script:CurrentMode)
        }
        catch {
            Set-Footer ("Mode change failed: {0}" -f $_.Exception.Message)
        }
    }
    else {
        $Script:CurrentMode = [string]$modeCombo.SelectedItem
        Update-Ui
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    Disconnect-Adapter -Quiet
    if ($null -ne $Script:Recorder) {
        $Script:CloseAfterRecording = $true
        $eventArgs.Cancel = $true
        $controlsPanel.Enabled = $false
        Update-RecordingControls
        return
    }
    $uiTimer.Stop()
})

Refresh-Ports
Set-ConnectionControls
Update-Ui

[void][System.Windows.Forms.Application]::Run($form)
