// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Swiss Army VPN Installer")]
[assembly: AssemblyDescription("Installs Swiss Army VPN without displaying a PowerShell console.")]
[assembly: AssemblyCompany("Justichuu")]
[assembly: AssemblyProduct("Swiss Army VPN")]
[assembly: AssemblyCopyright("Copyright (c) Justichuu")]
[assembly: AssemblyVersion("1.5.1.0")]
[assembly: AssemblyFileVersion("1.5.1.0")]
[assembly: AssemblyInformationalVersion("1.5.1.0")]

namespace SwissArmyVpn.Installer
{
    internal enum InstallerStatus
    {
        Starting,
        ValidatingPackage,
        Running,
        Completed,
        Failed
    }

    internal sealed class InstallerConfiguration
    {
        internal InstallerConfiguration(string packageDirectory)
        {
            PackageDirectory = packageDirectory;
            PowerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            InstallerScriptPath = GetInstallerScriptPath(packageDirectory);
        }

        internal string PackageDirectory { get; private set; }
        internal string PowerShellPath { get; private set; }
        internal string InstallerScriptPath { get; private set; }

        private static string GetInstallerScriptPath(string packageDirectory)
        {
            string primaryScript = Path.Combine(
                packageDirectory,
                "Programs",
                "PowershellBackup",
                "Install Swiss Army VPN.ps1");
            if (File.Exists(primaryScript))
                return primaryScript;

            string fallbackScript = Path.GetFullPath(Path.Combine(
                packageDirectory,
                "..",
                "installer",
                "Programs",
                "PowershellBackup",
                "Install Swiss Army VPN.ps1"));
            if (File.Exists(fallbackScript))
                return fallbackScript;

            return primaryScript;
        }
    }

    internal static class Program
    {
        private const string DialogTitle = "Swiss Army VPN Installer";
        private static InstallerStatus status = InstallerStatus.Starting;

        /// <summary>
        /// Validates the extracted package and runs its hardened PowerShell installer with no console window.
        /// The native launcher is elevated by its manifest so the script never has to open a second host.
        /// </summary>
        [STAThread]
        private static int Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                InstallerConfiguration configuration = CreateConfiguration();
                status = InstallerStatus.ValidatingPackage;
                ValidateConfiguration(configuration);

                status = InstallerStatus.Running;
                int exitCode = RunInstaller(configuration);
                status = exitCode == 0 ? InstallerStatus.Completed : InstallerStatus.Failed;
                return exitCode;
            }
            catch (Win32Exception exception)
            {
                status = InstallerStatus.Failed;
                ShowFailure("Windows could not start the installer.", exception);
                return 2;
            }
            catch (InvalidOperationException exception)
            {
                status = InstallerStatus.Failed;
                ShowFailure("The installer package is incomplete or invalid.", exception);
                return 2;
            }
            catch (Exception exception)
            {
                status = InstallerStatus.Failed;
                ShowFailure("Installation could not start.", exception);
                return 2;
            }
        }

        private static InstallerConfiguration CreateConfiguration()
        {
            string packageDirectory = AppDomain.CurrentDomain.BaseDirectory;
            if (string.IsNullOrWhiteSpace(packageDirectory))
                throw new InvalidOperationException("Windows could not determine the extracted package folder.");

            return new InstallerConfiguration(Path.GetFullPath(packageDirectory));
        }

        private static void ValidateConfiguration(InstallerConfiguration configuration)
        {
            if (!File.Exists(configuration.PowerShellPath))
                throw new InvalidOperationException("Windows PowerShell is not available on this computer.");
            if (!File.Exists(configuration.InstallerScriptPath))
                throw new InvalidOperationException(
                    "Keep the installer beside the Programs folder and extract the complete ZIP before running it.");
        }

        private static int RunInstaller(InstallerConfiguration configuration)
        {
            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = configuration.PowerShellPath,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                    QuoteArgument(configuration.InstallerScriptPath),
                WorkingDirectory = configuration.PackageDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                    throw new InvalidOperationException("Windows did not return an installer process.");

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
                    Environment.NewLine + Environment.NewLine + "Installer status: " + status,
                DialogTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
