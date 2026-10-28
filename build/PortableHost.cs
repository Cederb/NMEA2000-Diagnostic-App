using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("NMEA2000 Diagnostics")]
[assembly: AssemblyDescription("Waveshare USB-CAN-A NMEA2000 bus diagnostics")]
[assembly: AssemblyProduct("NMEA2000 Diagnostics")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

internal static class PortableHost
{
    [STAThread]
    private static int Main()
    {
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);

        try
        {
            return RunApplication();
        }
        catch (Exception exception)
        {
            ShowFailure(exception.ToString());
            return 1;
        }
    }

    private static int RunApplication()
    {
        string source;
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("NMEA2000Diagnostics.ps1"))
        {
            if (stream == null)
            {
                throw new InvalidOperationException("The embedded application could not be found.");
            }

            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                source = reader.ReadToEnd();
            }
        }

        using (Runspace runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
        {
            // WinForms callbacks must run on the same STA thread as the script.
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            runspace.SessionStateProxy.SetVariable("ErrorActionPreference", ActionPreference.Stop);

            using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                shell.AddScript(source, false);
                shell.Invoke();

                if (shell.HadErrors)
                {
                    StringBuilder details = new StringBuilder();
                    foreach (ErrorRecord error in shell.Streams.Error)
                    {
                        details.AppendLine(error.ToString());
                        details.AppendLine(error.ScriptStackTrace);
                    }

                    ShowFailure(details.ToString());
                    return 1;
                }
            }
        }

        return 0;
    }

    private static void ShowFailure(string details)
    {
        string message = "NMEA2000 Diagnostics encountered an error.\r\n\r\n";
        try
        {
            string logPath = Path.Combine(Path.GetTempPath(), "NMEA2000Diagnostics-error.log");
            File.WriteAllText(logPath, DateTime.UtcNow.ToString("O") + "\r\n" + details, Encoding.UTF8);
            message += "Error details were saved to:\r\n" + logPath;
        }
        catch
        {
            message += details;
        }

        MessageBox.Show(message, "NMEA2000 Diagnostics", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
