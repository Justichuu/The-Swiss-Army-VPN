using System;
using System.IO;

namespace SwissArmyVpn.Installer
{
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

        internal string PackageDirectory { get; }
        internal string PowerShellPath { get; }
        internal string InstallerScriptPath { get; }

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
}
