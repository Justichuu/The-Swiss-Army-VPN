using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace SwitzerlandVpn.Installer
{
    internal static class Program
    {
        private const string DialogTitle = "Switzerland VPN Installer";
        private static InstallerStatus status = InstallerStatus.Starting;

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
