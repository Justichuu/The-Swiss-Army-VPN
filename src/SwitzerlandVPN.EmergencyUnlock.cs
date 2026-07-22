// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Switzerland VPN Emergency Unlock")]
[assembly: AssemblyDescription("Restores normal internet access without displaying a PowerShell console.")]
[assembly: AssemblyCompany("Justichuu")]
[assembly: AssemblyProduct("Switzerland VPN")]
[assembly: AssemblyCopyright("Copyright (c) Justichuu")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]
[assembly: AssemblyInformationalVersion("1.3.0")]

namespace SwitzerlandVpn.EmergencyUnlock
{
    internal enum UnlockStatus
    {
        Starting,
        Validating,
        Running,
        Completed,
        Failed
    }

    internal sealed class UnlockConfiguration
    {
        internal UnlockConfiguration(string workingDirectory, string scriptPath)
        {
            WorkingDirectory = workingDirectory;
            ScriptPath = scriptPath;
            PowerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
        }

        internal string WorkingDirectory { get; private set; }
        internal string ScriptPath { get; private set; }
        internal string PowerShellPath { get; private set; }
    }

    internal static class Program
    {
        private const string DialogTitle = "Switzerland VPN Emergency Unlock";
        private static UnlockStatus status = UnlockStatus.Starting;

        /// <summary>
        /// Runs the verified emergency recovery script in a hidden PowerShell process.
        /// Elevation is handled by the executable manifest so no console host is shown.
        /// </summary>
        [STAThread]
        private static int Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                UnlockConfiguration configuration = CreateConfiguration();
                status = UnlockStatus.Validating;
                ValidateConfiguration(configuration);
                status = UnlockStatus.Running;
                int exitCode = RunUnlock(configuration);
                status = exitCode == 0 ? UnlockStatus.Completed : UnlockStatus.Failed;
                return exitCode;
            }
            catch (Win32Exception exception)
            {
                status = UnlockStatus.Failed;
                ShowFailure("Windows could not start Emergency Unlock.", exception);
                return 2;
            }
            catch (InvalidOperationException exception)
            {
                status = UnlockStatus.Failed;
                ShowFailure("Emergency Unlock is incomplete or invalid.", exception);
                return 2;
            }
            catch (Exception exception)
            {
                status = UnlockStatus.Failed;
                ShowFailure("Emergency Unlock could not start.", exception);
                return 2;
            }
        }

        private static UnlockConfiguration CreateConfiguration()
        {
            string executableDirectory = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory);
            string installedScript = Path.Combine(executableDirectory, "Emergency Unlock.ps1");
            if (File.Exists(installedScript))
                return new UnlockConfiguration(executableDirectory, installedScript);

            string packageScript = Path.GetFullPath(Path.Combine(
                executableDirectory,
                "..",
                "PowershellBackup",
                "Emergency Unlock.ps1"));
            return new UnlockConfiguration(executableDirectory, packageScript);
        }

        private static void ValidateConfiguration(UnlockConfiguration configuration)
        {
            if (!File.Exists(configuration.PowerShellPath))
                throw new InvalidOperationException("Windows PowerShell is not available on this computer.");
            if (!File.Exists(configuration.ScriptPath))
                throw new InvalidOperationException("Emergency Unlock.ps1 is missing. Reinstall Switzerland VPN.");
        }

        private static int RunUnlock(UnlockConfiguration configuration)
        {
            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = configuration.PowerShellPath,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                    QuoteArgument(configuration.ScriptPath),
                WorkingDirectory = configuration.WorkingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                    throw new InvalidOperationException("Windows did not return an Emergency Unlock process.");
                process.WaitForExit();
                return process.ExitCode;
            }
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void ShowFailure(string summary, Exception exception)
        {
            MessageBox.Show(
                summary + Environment.NewLine + Environment.NewLine + exception.Message +
                    Environment.NewLine + Environment.NewLine + "Unlock status: " + status,
                DialogTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
