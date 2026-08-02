using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Globalization;
using System.Linq;
using Microsoft.Win32;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Switzerland VPN")]
[assembly: System.Reflection.AssemblyDescription("Switzerland VPN kill-switch widget")]
[assembly: System.Reflection.AssemblyCompany("Justichuu")]
[assembly: System.Reflection.AssemblyProduct("Switzerland VPN")]
[assembly: System.Reflection.AssemblyCopyright("Copyright 2026 Justichuu")]
[assembly: System.Reflection.AssemblyVersion("1.4.3.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.4.3.0")]
[assembly: System.Reflection.AssemblyInformationalVersion("1.4.3.0")]

namespace SwitzerlandVpn
{
    internal static class AppConfig
    {
        internal const string VpnName = "Switzerland VPN";
        internal const string RuleGroup = "Switzerland VPN Kill Switch";
        internal const string Publisher = "Justichuu";
        // The project handle changed because I got bored; keep the old publisher only for safe upgrades.
        internal const string LegacyPublisher = "Jaye";
        internal const string DefaultServer = "ch221.nordvpn.com";
        internal const string CurrentVersion = "1.4.3";
        internal const string GitHubRepository = "Justichuu/The-Swiss-Army-VPN";
        internal const string RepositoryUrl = "https://github.com/Justichuu/The-Swiss-Army-VPN";
        internal const string UpdateScriptName = "Update Switzerland VPN.ps1";
        internal const string ServerSwitcherScriptName = "Switch Switzerland VPN Server.ps1";
        internal const string RuleDescriptionPrefix =
            "Switzerland VPN fail-closed rule. Allowed server IPv4 addresses: ";

        internal static readonly string[] RuleNames =
        {
            "Switzerland VPN Kill Switch - Wired IPv4",
            "Switzerland VPN Kill Switch - Wired IPv6",
            "Switzerland VPN Kill Switch - Wireless IPv4",
            "Switzerland VPN Kill Switch - Wireless IPv6"
        };

        internal static string ServerHost
        {
            get
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "VPN Server.txt");
                if (!File.Exists(path)) return DefaultServer;
                string value = File.ReadAllText(path).Trim();
                return value.Length == 0 ? DefaultServer : value;
            }
        }

        internal static string[] SwissServerPool
        {
            get
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "VPN Servers.txt");
                if (!File.Exists(path)) return new[] { DefaultServer };
                return File.ReadAllLines(path)
                    .Select(value => value.Trim().ToLowerInvariant())
                    .Where(NetworkSafety.IsSwissNordVpnHostname)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
                    .ToArray();
            }
        }

        internal static bool AllowAnyNordVpnServer
        {
            get
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Justichuu\Switzerland VPN"))
                    return key != null && Convert.ToInt32(key.GetValue("AllowAnyNordVpnServer", 0), CultureInfo.InvariantCulture) == 1;
            }
            set
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Justichuu\Switzerland VPN"))
                {
                    if (key == null) throw new InvalidOperationException("Windows could not save the server selection mode.");
                    key.SetValue("AllowAnyNordVpnServer", value ? 1 : 0, RegistryValueKind.DWord);
                }
            }
        }

        internal static bool IsSupportedPublisher(string value)
        {
            return string.Equals(value, Publisher, StringComparison.Ordinal) ||
                string.Equals(value, LegacyPublisher, StringComparison.Ordinal);
        }
    }

    internal sealed class WidgetState
    {
        internal bool Connected;
        internal bool ConnectionAmbiguous;
        internal IntPtr ConnectionHandle;
        internal uint TunnelInterfaceIndex;
        internal bool KillSwitchActive;
        internal bool KillSwitchIncomplete;
        internal bool FirewallProtectionOff;
        internal bool ManagedRulesPresent;
        internal WidgetDisplayState? PreviewDisplayState;
        internal bool PreviewTelemetryAvailable;
        internal long PreviewLatencyMilliseconds;
        internal double PreviewDownloadMbps;
        internal double PreviewUploadMbps;
        internal string Error;
    }

    internal enum WidgetDisplayState
    {
        Disconnected,
        Connecting,
        ConnectingOnly,
        ArmingOnly,
        PreparingSignIn,
        Disconnecting,
        DisconnectingOnly,
        UnlockingOnly,
        Protected,
        ConnectedWithoutProtection,
        InternetBlocked,
        ProtectionIncomplete,
        FirewallProtectionOff,
        Unavailable
    }

    internal enum VpnOperation
    {
        None,
        Connect,
        ConnectOnly,
        ArmOnly,
        PrepareSignIn,
        Disconnect,
        DisconnectOnly,
        UnlockOnly,
        ClearCredentials,
        ChangeServer,
        CheckingUpdate,
        AwaitingUpdateConfirmation,
        PreparingUpdate,
        StartingUpdate
    }

    internal enum UpdateCheckState
    {
        Idle,
        Checking,
        AwaitingConfirmation,
        Preparing,
        Starting,
        Failed
    }

    internal sealed class GitHubReleaseInfo
    {
        internal string TagName;
        internal string VersionText;
        internal Version Version;
        internal bool Immutable;
        internal string GitHubCliPath;
    }

    internal sealed class ProcessResult
    {
        internal int ExitCode;
        internal string StandardOutput;
        internal string StandardError;
    }

    internal enum UpdateRecoveryLaunchState
    {
        None,
        Started,
        Failed
    }

    internal sealed class UpdateRecoveryLaunchResult
    {
        internal UpdateRecoveryLaunchState State;
        internal string ErrorMessage;
    }

    /// <summary>
    /// Detects a protected update journal before the normal widget opens. Recovery runs in the
    /// installed PowerShell helper after this process exits, so even the executable can be restored.
    /// </summary>
    internal static class PrivateUpdateRecoveryManager
    {
        internal static UpdateRecoveryLaunchResult StartPendingRecovery()
        {
            try
            {
                string stateDirectory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    AppConfig.VpnName);
                string journalPath = Path.Combine(stateDirectory, "update-journal.json");
                string previousJournalPath = Path.Combine(stateDirectory, "update-journal.previous.json");
                if (!File.Exists(journalPath) && !File.Exists(previousJournalPath))
                    return new UpdateRecoveryLaunchResult { State = UpdateRecoveryLaunchState.None };

                string statePath = Path.Combine(stateDirectory, "install-state.json");
                if (!Directory.Exists(stateDirectory) || !File.Exists(statePath))
                    throw new InvalidOperationException("Update recovery data is incomplete. Ask Justichuu for help.");
                AssertNormalPath(stateDirectory, true);
                AssertNormalPath(statePath, false);

                string state = File.ReadAllText(statePath);
                string installDirectory = Path.GetFullPath(ReadJsonStringProperty(state, "InstallDirectory")).TrimEnd('\\');
                string runningDirectory = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
                if (!string.Equals(installDirectory, runningDirectory, StringComparison.OrdinalIgnoreCase) ||
                    !string.Equals(Path.GetFileName(installDirectory), AppConfig.VpnName, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Update recovery must be started by the installed Switzerland VPN app.");
                }

                string root = Path.GetPathRoot(installDirectory);
                DriveInfo drive = new DriveInfo(root);
                if (!drive.IsReady || drive.DriveType != DriveType.Fixed)
                    throw new InvalidOperationException("The installed app is not on a ready local fixed drive.");
                AssertNormalPath(installDirectory, true);

                string updateScript = Path.Combine(installDirectory, AppConfig.UpdateScriptName);
                AssertNormalPath(updateScript, false);
                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershell))
                    throw new InvalidOperationException("Windows PowerShell is unavailable, so update recovery could not start.");

                using (Process current = Process.GetCurrentProcess())
                {
                    string[] arguments =
                    {
                        "-NoProfile",
                        "-ExecutionPolicy", "Bypass",
                        "-WindowStyle", "Hidden",
                        "-File", updateScript,
                        "-RecoverOnly",
                        "-ParentProcessId", current.Id.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        "-ParentProcessStartTimeUtcTicks", current.StartTime.ToUniversalTime().Ticks.ToString(
                            System.Globalization.CultureInfo.InvariantCulture)
                    };
                    ProcessStartInfo startInfo = new ProcessStartInfo
                    {
                        FileName = powershell,
                        Arguments = string.Join(
                            " ",
                            arguments.Select(PrivateUpdateManager.QuoteArgument).ToArray()),
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WindowStyle = ProcessWindowStyle.Hidden,
                        WorkingDirectory = installDirectory
                    };
                    using (Process recovery = Process.Start(startInfo))
                    {
                        if (recovery == null)
                            throw new InvalidOperationException("Windows did not start update recovery.");
                    }
                }
                return new UpdateRecoveryLaunchResult { State = UpdateRecoveryLaunchState.Started };
            }
            catch (Exception ex)
            {
                return new UpdateRecoveryLaunchResult
                {
                    State = UpdateRecoveryLaunchState.Failed,
                    ErrorMessage = string.IsNullOrWhiteSpace(ex.Message)
                        ? "Windows could not start update recovery. Ask Justichuu for help."
                        : ex.Message
                };
            }
        }

        private static void AssertNormalPath(string path, bool directory)
        {
            bool exists = directory ? Directory.Exists(path) : File.Exists(path);
            if (!exists || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Update recovery found a missing or linked protected path.");
        }

        private static string ReadJsonStringProperty(string json, string propertyName)
        {
            Match match = Regex.Match(
                json ?? string.Empty,
                "\\\"" + Regex.Escape(propertyName) + "\\\"\\s*:\\s*\\\"(?<value>(?:\\\\.|[^\\\"])*)\\\"",
                RegexOptions.CultureInvariant);
            if (!match.Success)
                throw new InvalidOperationException("Update recovery could not read the installed app location.");
            return Regex.Unescape(match.Groups["value"].Value);
        }
    }

    /// <summary>
    /// Locates GitHub CLI and reads private release metadata without exposing or copying its token.
    /// All calls are direct child processes; no command shell is involved.
    /// </summary>
    internal static class PrivateUpdateManager
    {
        private const int AuthenticationTimeoutMilliseconds = 15000;
        private const int ReleaseTimeoutMilliseconds = 30000;
        private const int MaximumCapturedCharacters = 65536;

        internal static GitHubReleaseInfo CheckLatestRelease()
        {
            string githubCli = FindGitHubCli();
            if (githubCli == null)
            {
                throw new InvalidOperationException(
                    "A system-wide GitHub CLI is not installed. Install it with winget install --id GitHub.cli, " +
                    "reopen Switzerland VPN, then try again.");
            }

            ProcessResult cliVersion = RunProcess(
                githubCli,
                new[] { "--version" },
                AuthenticationTimeoutMilliseconds);
            Match cliVersionMatch = Regex.Match(
                cliVersion.StandardOutput ?? string.Empty,
                @"(?m)^gh version (\d+)\.(\d+)\.(\d+)",
                RegexOptions.CultureInvariant);
            Version parsedCliVersion;
            if (cliVersion.ExitCode != 0 || !cliVersionMatch.Success ||
                !Version.TryParse(
                    cliVersionMatch.Groups[1].Value + "." +
                    cliVersionMatch.Groups[2].Value + "." +
                    cliVersionMatch.Groups[3].Value,
                    out parsedCliVersion) ||
                parsedCliVersion < new Version(2, 96, 0))
            {
                throw new InvalidOperationException(
                    "GitHub CLI 2.96 or newer is required. Update it with winget upgrade --id GitHub.cli, " +
                    "reopen Switzerland VPN, then try again.");
            }

            ProcessResult authentication;
            try
            {
                authentication = RunProcess(
                    githubCli,
                    new[] { "auth", "status", "--active", "--hostname", "github.com" },
                    AuthenticationTimeoutMilliseconds);
            }
            catch (System.TimeoutException)
            {
                throw new InvalidOperationException(
                    "GitHub did not respond in time. Check the VPN or internet connection, then try again.");
            }

            if (authentication.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    "GitHub CLI is not signed in. Open PowerShell, run gh auth login, and sign in with an " +
                    "account that can access the private repository.");
            }

            const string query =
                "(.tag_name // \"\") + \"|\" + ((.immutable // false) | tostring) + \"|\" + " +
                "((.draft // false) | tostring) + \"|\" + ((.prerelease // false) | tostring)";
            ProcessResult release;
            try
            {
                release = RunProcess(
                    githubCli,
                    new[]
                    {
                        "api",
                        "--hostname", "github.com",
                        "repos/" + AppConfig.GitHubRepository + "/releases/latest",
                        "--jq", query
                    },
                    ReleaseTimeoutMilliseconds);
            }
            catch (System.TimeoutException)
            {
                throw new InvalidOperationException(
                    "GitHub did not respond in time. Check the VPN or internet connection, then try again.");
            }

            if (release.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    "GitHub could not read the private release. Make sure this GitHub account has access to " +
                    AppConfig.GitHubRepository + ", then try again.");
            }

            string[] fields = (release.StandardOutput ?? string.Empty).Trim().Split('|');
            if (fields.Length != 4 ||
                !string.Equals(fields[2], "false", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(fields[3], "false", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "GitHub did not return a normal published release. Nothing was downloaded.");
            }

            Match tag = Regex.Match(fields[0], @"^v(\d+)\.(\d+)\.(\d+)$", RegexOptions.CultureInvariant);
            if (!tag.Success)
            {
                throw new InvalidOperationException(
                    "The latest release tag is not a supported version number. Expected v1.2.3. Nothing was downloaded.");
            }
            if (!string.Equals(fields[1], "true", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "The latest release is not locked against changes. Update stopped safely. " +
                    "Ask Justichuu to publish an immutable release.");
            }

            string versionText = string.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                "{0}.{1}.{2}",
                tag.Groups[1].Value,
                tag.Groups[2].Value,
                tag.Groups[3].Value);
            Version version;
            if (!Version.TryParse(versionText, out version))
                throw new InvalidOperationException("The latest release version could not be read safely.");

            return new GitHubReleaseInfo
            {
                TagName = fields[0],
                VersionText = versionText,
                Version = version,
                Immutable = string.Equals(fields[1], "true", StringComparison.OrdinalIgnoreCase),
                GitHubCliPath = githubCli
            };
        }

        internal static string QuoteArgument(string value)
        {
            if (value == null) throw new ArgumentNullException("value");
            if (value.Length == 0) return "\"\"";
            if (value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;

            StringBuilder quoted = new StringBuilder();
            quoted.Append('\"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }

                if (character == '\"')
                {
                    quoted.Append('\\', (backslashes * 2) + 1);
                    quoted.Append('\"');
                }
                else
                {
                    quoted.Append('\\', backslashes);
                    quoted.Append(character);
                }
                backslashes = 0;
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('\"');
            return quoted.ToString();
        }

        private static string FindGitHubCli()
        {
            List<string> candidates = new List<string>();
            AddCandidate(candidates, Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "GitHub CLI", "gh.exe"));
            AddCandidate(candidates, Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                "GitHub CLI", "gh.exe"));
            return candidates.FirstOrDefault(File.Exists);
        }

        private static void AddCandidate(List<string> candidates, string candidate)
        {
            if (string.IsNullOrWhiteSpace(candidate)) return;
            if (!Path.IsPathRooted(candidate) || candidate.StartsWith("\\\\", StringComparison.Ordinal)) return;
            if (!candidates.Contains(candidate, StringComparer.OrdinalIgnoreCase)) candidates.Add(candidate);
        }

        private static ProcessResult RunProcess(string fileName, IEnumerable<string> arguments, int timeoutMilliseconds)
        {
            if (string.IsNullOrWhiteSpace(fileName)) throw new ArgumentException("Program path is required.", "fileName");
            if (arguments == null) throw new ArgumentNullException("arguments");

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = string.Join(" ", arguments.Select(QuoteArgument).ToArray()),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            foreach (string variableName in new[] { "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_REPO", "GH_CONFIG_DIR" })
                startInfo.EnvironmentVariables.Remove(variableName);
            StringBuilder standardOutput = new StringBuilder();
            StringBuilder standardError = new StringBuilder();
            object outputLock = new object();

            using (Process process = new Process { StartInfo = startInfo })
            {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) return;
                    lock (outputLock)
                    {
                        if (standardOutput.Length < MaximumCapturedCharacters)
                            standardOutput.AppendLine(e.Data.Substring(
                                0,
                                Math.Min(e.Data.Length, MaximumCapturedCharacters - standardOutput.Length)));
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) return;
                    lock (outputLock)
                    {
                        if (standardError.Length < MaximumCapturedCharacters)
                            standardError.AppendLine(e.Data.Substring(
                                0,
                                Math.Min(e.Data.Length, MaximumCapturedCharacters - standardError.Length)));
                    }
                };

                if (!process.Start()) throw new InvalidOperationException("GitHub CLI could not start.");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    try { process.Kill(); }
                    catch (InvalidOperationException) { }
                    process.WaitForExit();
                    throw new System.TimeoutException();
                }
                process.WaitForExit();
                lock (outputLock)
                {
                    return new ProcessResult
                    {
                        ExitCode = process.ExitCode,
                        StandardOutput = standardOutput.ToString(),
                        StandardError = standardError.ToString()
                    };
                }
            }
        }
    }

    internal sealed class RasConnection
    {
        internal string Name;
        internal IntPtr Handle;
    }

    internal sealed class RasConnectionStatistics
    {
        internal uint BytesSent;
        internal uint BytesReceived;
        internal uint ConnectDurationMilliseconds;
    }

    internal static class RasManager
    {
        private const uint ErrorSuccess = 0;
        private const uint ErrorBufferTooSmall = 603;
        private const uint RasCredentialUserName = 0x00000001;
        private const uint RasCredentialPassword = 0x00000002;
        private const uint RasCredentialDomain = 0x00000004;
        private const uint RasCredentialDefault = 0x00000008;
        private const int RasConnectionStateConnected = 0x2000;
        private const uint RasApiVersionCurrent = 4;
        private const int RasProjectionInfoTypeIkev2 = 2;
        private const uint RasProjectionInfoBaseSize = 108;
        private const uint RasProjectionInfoMaximumSize = 65536;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
        private struct RASCONN
        {
            public int dwSize;
            public IntPtr hrasconn;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)]
            public string szEntryName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)]
            public string szDeviceType;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)]
            public string szDeviceName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szPhonebook;

            public int dwSubEntry;
            public Guid guidEntry;
            public int dwFlags;
            public ulong logonSessionLuid;
            public Guid guidCorrelationId;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
        private struct RASCREDENTIALS
        {
            public int dwSize;
            public uint dwMask;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)]
            public string szUserName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)]
            public string szPassword;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]
            public string szDomain;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
        private struct RASCONNSTATUS
        {
            public int dwSize;
            public int rasconnstate;
            public uint dwError;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)]
            public string szDeviceType;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)]
            public string szDeviceName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)]
            public string szPhoneNumber;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct RAS_STATS
        {
            public uint dwSize;
            public uint dwBytesXmited;
            public uint dwBytesRcved;
            public uint dwFramesXmited;
            public uint dwFramesRcved;
            public uint dwCrcErr;
            public uint dwTimeoutErr;
            public uint dwAlignmentErr;
            public uint dwHardwareOverrunErr;
            public uint dwFramingErr;
            public uint dwBufferOverrunErr;
            public uint dwCompressionRatioIn;
            public uint dwCompressionRatioOut;
            public uint dwBps;
            public uint dwConnectDuration;
        }

        [DllImport("rasapi32.dll", EntryPoint = "RasEnumConnectionsW", CharSet = CharSet.Unicode)]
        private static extern uint RasEnumConnections(IntPtr connections, ref int bufferSize, out int connectionCount);

        [DllImport("rasapi32.dll", EntryPoint = "RasHangUpW")]
        private static extern uint RasHangUp(IntPtr connection);

        [DllImport("rasapi32.dll", EntryPoint = "RasSetCredentialsW", CharSet = CharSet.Unicode)]
        private static extern uint RasSetCredentials(
            string phonebook,
            string entryName,
            ref RASCREDENTIALS credentials,
            [MarshalAs(UnmanagedType.Bool)] bool clearCredentials);

        [DllImport("rasapi32.dll", EntryPoint = "RasGetCredentialsW", CharSet = CharSet.Unicode)]
        private static extern uint RasGetCredentials(
            string phonebook,
            string entryName,
            ref RASCREDENTIALS credentials);

        [DllImport("rasapi32.dll", EntryPoint = "RasGetConnectStatusW", CharSet = CharSet.Unicode)]
        private static extern uint RasGetConnectStatus(
            IntPtr connection,
            ref RASCONNSTATUS status);

        [DllImport("rasapi32.dll", EntryPoint = "RasGetConnectionStatistics")]
        private static extern uint RasGetConnectionStatistics(
            IntPtr connection,
            ref RAS_STATS statistics);

        [DllImport("rasapi32.dll", EntryPoint = "RasGetProjectionInfoEx", ExactSpelling = true)]
        private static extern uint RasGetProjectionInfoEx(
            IntPtr connection,
            IntPtr projection,
            ref uint bufferSize);

        internal static List<RasConnection> GetConnections()
        {
            int bufferSize = 0;
            int connectionCount;
            uint result = RasEnumConnections(IntPtr.Zero, ref bufferSize, out connectionCount);

            if (result == ErrorSuccess && connectionCount == 0)
                return new List<RasConnection>();

            if (result != ErrorBufferTooSmall && result != ErrorSuccess)
                throw new Win32Exception((int)result, "Windows could not read the active VPN connections.");

            int structureSize = Marshal.SizeOf(typeof(RASCONN));
            if (bufferSize < structureSize) bufferSize = structureSize;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);

            try
            {
                for (int attempt = 0; attempt < 2; attempt++)
                {
                    for (int offset = 0; offset + structureSize <= bufferSize; offset += structureSize)
                        Marshal.WriteInt32(buffer, offset, structureSize);

                    int suppliedSize = bufferSize;
                    result = RasEnumConnections(buffer, ref suppliedSize, out connectionCount);

                    if (result == ErrorBufferTooSmall && suppliedSize > bufferSize)
                    {
                        IntPtr replacement = Marshal.AllocHGlobal(suppliedSize);
                        Marshal.FreeHGlobal(buffer);
                        bufferSize = suppliedSize;
                        buffer = replacement;
                        continue;
                    }

                    if (result != ErrorSuccess)
                        throw new Win32Exception((int)result, "Windows could not read the active VPN connections.");

                    List<RasConnection> connections = new List<RasConnection>();
                    for (int index = 0; index < connectionCount; index++)
                    {
                        IntPtr item = IntPtr.Add(buffer, index * structureSize);
                        RASCONN value = (RASCONN)Marshal.PtrToStructure(item, typeof(RASCONN));
                        connections.Add(new RasConnection
                        {
                            Name = value.szEntryName ?? string.Empty,
                            Handle = value.hrasconn
                        });
                    }
                    return connections;
                }

                throw new InvalidOperationException("The active VPN list changed while it was being read. Try again.");
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        internal static bool IsConnected(string name)
        {
            return GetConnections().Any(c =>
                string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase) &&
                IsConnectionEstablished(c.Handle));
        }

        /// <summary>
        /// Confirms that an exact live RAS handle has reached the connected state and has no
        /// connection-level error. Enumeration alone is insufficient because dialing and teardown
        /// handles can remain visible temporarily.
        /// </summary>
        internal static bool IsConnectionEstablished(IntPtr connection)
        {
            if (connection == IntPtr.Zero) return false;
            RASCONNSTATUS status = new RASCONNSTATUS
            {
                dwSize = Marshal.SizeOf(typeof(RASCONNSTATUS)),
                szDeviceType = string.Empty,
                szDeviceName = string.Empty,
                szPhoneNumber = string.Empty
            };
            uint result = RasGetConnectStatus(connection, ref status);
            if (result != ErrorSuccess) return false;
            return status.rasconnstate == RasConnectionStateConnected && status.dwError == 0;
        }

        /// <summary>
        /// Maps one exact IKEv2 RAS handle to its Windows IPv4 interface index by reading the
        /// handle's documented projection address and finding the one adapter that owns it. An
        /// unavailable or ambiguous mapping returns zero; this method never guesses an adapter.
        /// </summary>
        internal static uint GetConnectionInterfaceIndex(IntPtr connection)
        {
            if (connection == IntPtr.Zero || !IsConnectionEstablished(connection)) return 0;

            IPAddress projectedAddress = TryGetProjectedIkev2Ipv4Address(connection);
            if (projectedAddress == null) return 0;
            List<uint> matches = FindIpv4InterfaceIndices(projectedAddress);
            return matches.Count == 1 ? matches[0] : 0;
        }

        /// <summary>
        /// Reads the binary IPv4 client address from the IKEv2 member of RAS_PROJECTION_INFO.
        /// The native union has architecture-dependent pointer fields after the values used here,
        /// so a bounded raw buffer keeps the shared leading layout exact on both x86 and x64.
        /// </summary>
        private static IPAddress TryGetProjectedIkev2Ipv4Address(IntPtr connection)
        {
            uint allocationSize = RasProjectionInfoBaseSize;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (allocationSize < RasProjectionInfoBaseSize ||
                    allocationSize > RasProjectionInfoMaximumSize)
                    return null;

                int byteCount = checked((int)allocationSize);
                IntPtr projection = Marshal.AllocHGlobal(byteCount);
                try
                {
                    Marshal.Copy(new byte[byteCount], 0, projection, byteCount);
                    Marshal.WriteInt32(projection, 0, checked((int)RasApiVersionCurrent));
                    uint returnedSize = allocationSize;
                    uint result = RasGetProjectionInfoEx(connection, projection, ref returnedSize);
                    if (result == ErrorBufferTooSmall && returnedSize > allocationSize)
                    {
                        allocationSize = returnedSize;
                        continue;
                    }
                    if (result != ErrorSuccess ||
                        returnedSize < 16 ||
                        Marshal.ReadInt32(projection, 4) != RasProjectionInfoTypeIkev2 ||
                        unchecked((uint)Marshal.ReadInt32(projection, 8)) != ErrorSuccess)
                        return null;

                    byte[] addressBytes = new byte[4];
                    Marshal.Copy(IntPtr.Add(projection, 12), addressBytes, 0, addressBytes.Length);
                    IPAddress address = new IPAddress(addressBytes);
                    if (address.AddressFamily != AddressFamily.InterNetwork ||
                        IPAddress.Any.Equals(address) ||
                        IPAddress.Loopback.Equals(address))
                        return null;
                    return address;
                }
                finally
                {
                    Marshal.FreeHGlobal(projection);
                }
            }
            return null;
        }

        private static List<uint> FindIpv4InterfaceIndices(IPAddress requiredAddress)
        {
            List<uint> matches = new List<uint>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up)
                    continue;
                try
                {
                    IPInterfaceProperties properties = adapter.GetIPProperties();
                    bool addressMatches = properties.UnicastAddresses.Any(unicast =>
                        unicast.Address != null &&
                        unicast.Address.AddressFamily == AddressFamily.InterNetwork &&
                        !IPAddress.Any.Equals(unicast.Address) &&
                        !IPAddress.Loopback.Equals(unicast.Address) &&
                        (requiredAddress == null || requiredAddress.Equals(unicast.Address)));
                    if (!addressMatches) continue;
                    IPv4InterfaceProperties ipv4 = properties.GetIPv4Properties();
                    if (ipv4 != null && ipv4.Index > 0)
                        matches.Add(checked((uint)ipv4.Index));
                }
                catch (NetworkInformationException) { }
            }
            return matches.Distinct().ToList();
        }

        /// <summary>
        /// Reads byte counters maintained by Windows for the exact RAS tunnel handle. These are
        /// cumulative tunnel counters, not an internet speed test.
        /// </summary>
        internal static RasConnectionStatistics ReadConnectionStatistics(IntPtr connection)
        {
            if (connection == IntPtr.Zero)
                throw new ArgumentException("A live RAS connection handle is required.", "connection");

            RAS_STATS statistics = new RAS_STATS
            {
                dwSize = (uint)Marshal.SizeOf(typeof(RAS_STATS))
            };
            uint result = RasGetConnectionStatistics(connection, ref statistics);
            if (result != ErrorSuccess)
                throw new Win32Exception((int)result, "Windows could not read live VPN traffic counters.");

            return new RasConnectionStatistics
            {
                BytesSent = statistics.dwBytesXmited,
                BytesReceived = statistics.dwBytesRcved,
                ConnectDurationMilliseconds = statistics.dwConnectDuration
            };
        }

        internal static void DisconnectOtherConnections(string managedName)
        {
            // RAS exposes live connection handles separately from saved phonebook entries.
            // Hanging up these handles preserves every profile and its saved configuration.
            // Windows does not expose enough ownership information here to restart displaced
            // sessions safely, so DISCONNECT + UNLOCK intentionally does not restore them.
            HashSet<IntPtr> requestedHandles = new HashSet<IntPtr>();
            DateTime deadline = DateTime.UtcNow.AddSeconds(12);

            try
            {
                while (DateTime.UtcNow < deadline)
                {
                    RasConnection[] others = GetConnections()
                        .Where(c => !string.Equals(c.Name, managedName, StringComparison.OrdinalIgnoreCase))
                        .ToArray();

                    if (others.Length == 0) return;

                    foreach (RasConnection connection in others)
                    {
                        // A connection can remain in the RAS list briefly while RasHangUp finishes.
                        // Request each handle once, but also catch a newly connected RAS session.
                        if (!requestedHandles.Add(connection.Handle)) continue;

                        uint result = RasHangUp(connection.Handle);
                        if (result != ErrorSuccess)
                        {
                            string displayName = string.IsNullOrWhiteSpace(connection.Name)
                                ? "an unnamed RAS connection"
                                : "'" + connection.Name + "'";
                            throw new Win32Exception((int)result,
                                "Windows would not disconnect " + displayName + ".");
                        }
                    }

                    Thread.Sleep(250);
                }

                string[] remaining = GetConnections()
                    .Where(c => !string.Equals(c.Name, managedName, StringComparison.OrdinalIgnoreCase))
                    .Select(c => string.IsNullOrWhiteSpace(c.Name) ? "(unnamed RAS connection)" : c.Name)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();

                if (remaining.Length == 0) return;

                throw new InvalidOperationException(
                    "These active RAS connections did not close:\r\n\r\n" +
                    string.Join("\r\n", remaining));
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException(
                    "Switzerland could not take over the active VPN connections. " +
                    "The kill switch remains armed, and no VPN profile was deleted. " +
                    "Use DISCONNECT + UNLOCK to restore normal networking.\r\n\r\n" +
                    ex.Message,
                    ex);
            }
        }

        internal static void Connect(string name, bool expectKillSwitch)
        {
            if (IsConnected(name)) return;

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "rasdial.exe"),
                Arguments = Quote(name),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            string output;
            int exitCode;
            using (Process process = Process.Start(startInfo))
            {
                output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
                process.WaitForExit();
                exitCode = process.ExitCode;
            }

            if (exitCode != 0)
                throw new InvalidOperationException(
                    BuildConnectFailureMessage(exitCode, output, expectKillSwitch));

            DateTime deadline = DateTime.UtcNow.AddSeconds(12);
            while (DateTime.UtcNow < deadline)
            {
                if (IsConnected(name)) return;
                Thread.Sleep(250);
            }

            string recovery = expectKillSwitch
                ? "Internet remains blocked until you use DISCONNECT + UNLOCK."
                : "CONNECT ONLY did not change the kill-switch state. Check the widget status before trying again.";
            throw new InvalidOperationException(
                "Windows finished dialing, but the VPN did not report a connected state. " + recovery);
        }

        internal static void Disconnect(string name)
        {
            RasConnection[] matches = GetConnections()
                .Where(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase))
                .ToArray();

            foreach (RasConnection match in matches)
            {
                uint result = RasHangUp(match.Handle);
                if (result != ErrorSuccess)
                    throw new Win32Exception((int)result, "Windows could not disconnect Switzerland VPN.");
            }

            DateTime deadline = DateTime.UtcNow.AddSeconds(12);
            while (DateTime.UtcNow < deadline)
            {
                if (!IsConnected(name)) return;
                Thread.Sleep(250);
            }

            throw new InvalidOperationException("Switzerland VPN is still connected after the disconnect request.");
        }

        internal static void OpenSignIn(string name)
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "rasphone.exe"),
                Arguments = "-d " + Quote(name),
                UseShellExecute = true
            });
        }

        /// <summary>
        /// Clears credentials saved specifically for the Windows account running this process.
        /// This must run before elevation changes the process identity.
        /// </summary>
        internal static void ClearCurrentUserCredentials(string name)
        {
            string phonebook = GetAllUsersPhonebook();

            if (!File.Exists(phonebook))
                throw new FileNotFoundException("The all-user Windows VPN phonebook was not found.", phonebook);

            uint identityMask = RasCredentialUserName | RasCredentialPassword | RasCredentialDomain;
            ClearCredentialMask(
                phonebook,
                name,
                identityMask,
                "Windows could not clear the sign-in saved for this Windows account.");
        }

        /// <summary>
        /// Clears machine-default credentials for an all-user RAS entry. The caller must be elevated.
        /// </summary>
        internal static void ClearDefaultCredentials(string name)
        {
            string phonebook = GetAllUsersPhonebook();

            if (!File.Exists(phonebook))
                throw new FileNotFoundException("The all-user Windows VPN phonebook was not found.", phonebook);

            uint identityMask = RasCredentialUserName | RasCredentialPassword | RasCredentialDomain;
            ClearCredentialMask(
                phonebook,
                name,
                identityMask | RasCredentialDefault,
                "Windows could not clear the shared default sign-in for Switzerland VPN.");
        }

        internal static bool HasSavedCredentials(string name)
        {
            string phonebook = GetAllUsersPhonebook();
            if (!File.Exists(phonebook))
                throw new InvalidOperationException(
                    "The Switzerland VPN profile is missing. Reinstall Switzerland VPN to restore it.");

            uint identityMask = RasCredentialUserName | RasCredentialPassword | RasCredentialDomain;
            return HasSavedPassword(phonebook, name, identityMask) ||
                   HasSavedPassword(phonebook, name, identityMask | RasCredentialDefault);
        }

        private static bool HasSavedPassword(string phonebook, string name, uint mask)
        {
            RASCREDENTIALS credentials = NewCredentials(mask);
            uint result = RasGetCredentials(phonebook, name, ref credentials);
            if (result == 623)
                throw new InvalidOperationException(
                    "The Switzerland VPN profile is missing. Reinstall Switzerland VPN to restore it.");
            if (result != ErrorSuccess)
                throw new InvalidOperationException(
                    "Windows could not check whether Switzerland VPN has a saved sign-in. " +
                    "Open SET UP SIGN-IN and try again.");
            bool hasUserName = (credentials.dwMask & RasCredentialUserName) != 0 &&
                !string.IsNullOrWhiteSpace(credentials.szUserName);
            bool hasPassword = (credentials.dwMask & RasCredentialPassword) != 0;
            return hasUserName && hasPassword;
        }

        private static void ClearCredentialMask(
            string phonebook,
            string name,
            uint mask,
            string failureMessage)
        {
            RASCREDENTIALS credentials = NewCredentials(mask);

            uint result = RasSetCredentials(phonebook, name, ref credentials, true);
            if (result != ErrorSuccess)
                throw new Win32Exception((int)result, failureMessage);
        }

        private static RASCREDENTIALS NewCredentials(uint mask)
        {
            return new RASCREDENTIALS
            {
                dwSize = Marshal.SizeOf(typeof(RASCREDENTIALS)),
                dwMask = mask,
                szUserName = string.Empty,
                szPassword = string.Empty,
                szDomain = string.Empty
            };
        }

        private static string GetAllUsersPhonebook()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Microsoft", "Network", "Connections", "Pbk", "rasphone.pbk");
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string BuildConnectFailureMessage(
            int exitCode,
            string output,
            bool expectKillSwitch)
        {
            int code = ExtractRasErrorCode(exitCode, output);
            string actionName = expectKillSwitch ? "CONNECT + ARM" : "CONNECT ONLY";
            string recovery = expectKillSwitch
                ? "\r\n\r\nThe kill switch is still armed, so internet remains blocked. " +
                  "Choose DISCONNECT + UNLOCK if you want to stop and restore normal internet."
                : "\r\n\r\nCONNECT ONLY did not change the kill-switch state. Check the widget status before choosing another action.";
            string normalInternetCheck = expectKillSwitch
                ? "\r\n\r\nAfter unlocking, confirm normal internet works."
                : "\r\n\r\nConfirm normal internet works.";

            switch (code)
            {
                case 703:
                    return
                        "Switzerland VPN does not have a usable saved sign-in.\r\n\r\n" +
                        "Choose SET UP SIGN-IN, enter the NordVPN manual service username and password, " +
                        "and save them. Then try " + actionName + " again. Ask Justichuu if you need the credentials." + recovery;
                case 691:
                    return
                        "Windows rejected the saved VPN username or password.\r\n\r\n" +
                        "Choose CLEAR SAVED CREDENTIALS, then SET UP SIGN-IN and enter the correct " +
                        "NordVPN manual service credentials." + recovery;
                case 623:
                    return
                        "The Switzerland VPN profile is missing. Reinstall Switzerland VPN to restore it." + recovery;
                case 633:
                case 756:
                case 910:
                    return
                        "Windows is already starting or stopping a VPN connection. Wait a few seconds, click REFRESH, " +
                        "and try again." + recovery;
                case 809:
                    return
                        "Windows could not reach the Switzerland VPN server." + recovery +
                        normalInternetCheck + " Then check the router or " +
                        "firewall before trying again.";
                case 868:
                    return
                        "Windows could not find the configured Switzerland VPN server." + recovery +
                        normalInternetCheck + " If it does, reinstall " +
                        "Switzerland VPN or check its server setting.";
                case 812:
                    return
                        "The VPN server refused the connection settings or account policy. Reinstall Switzerland VPN " +
                        "and try again. Ask Justichuu if it still fails." + recovery;
                case 13801:
                    return
                        "Windows could not verify the VPN server's security credentials. Reinstall Switzerland VPN " +
                        "to restore its certificate and profile settings, then try again." + recovery;
            }

            string message = code > 0
                ? "Windows could not connect to Switzerland VPN (error " + code + ")."
                : "Windows could not connect to Switzerland VPN.";
            return message + recovery;
        }

        private static int ExtractRasErrorCode(int exitCode, string output)
        {
            Match match = Regex.Match(output ?? string.Empty,
                @"Remote Access error\s+(\d+)", RegexOptions.IgnoreCase);
            int parsed;
            if (match.Success && int.TryParse(match.Groups[1].Value, out parsed)) return parsed;
            return exitCode >= 600 && exitCode <= 20000 ? exitCode : 0;
        }

    }

    internal sealed class FirewallRuleState
    {
        internal int Found;
        internal int Valid;
        internal string AllowedServerMetadata;
    }

    internal sealed class FirewallProtectionException : InvalidOperationException
    {
        internal FirewallProtectionException(string message) : base(message) { }
    }

    internal static class FirewallManager
    {
        private const int DirectionOutbound = 2;
        private const int ActionBlock = 0;
        private const int ProtocolAny = 256;
        private const int AllProfiles = 0x7fffffff;

        internal static void AssertFirewallAvailable()
        {
            using (ServiceController controller = new ServiceController("MpsSvc"))
            {
                if (controller.Status != ServiceControllerStatus.Running)
                    throw new FirewallProtectionException(
                        "Windows Defender Firewall is not running. Turn it on before arming kill-switch protection.");
            }

            object policyObject = null;
            try
            {
                policyObject = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true));
                dynamic policy = policyObject;
                int currentProfiles = (int)policy.CurrentProfileTypes;
                foreach (int profile in new[] { 1, 2, 4 })
                {
                    if ((currentProfiles & profile) == 0) continue;
                    bool enabled = (bool)policy.FirewallEnabled[profile];
                    if (!enabled)
                        throw new FirewallProtectionException(
                            "Windows Defender Firewall is disabled for an active network. Turn it on before arming kill-switch protection.");
                }
            }
            finally
            {
                Release(policyObject);
            }
        }

        /// <summary>
        /// Reads and validates the managed rules only after confirming that Windows Firewall is
        /// running and enabled for every active profile. Callers may treat a fully valid result as
        /// enforced protection.
        /// </summary>
        internal static FirewallRuleState GetRuleState()
        {
            AssertFirewallAvailable();
            return GetStoredRuleState();
        }

        /// <summary>
        /// Reads stored rule objects without claiming that Windows Firewall is enforcing them.
        /// This is used only for cleanup verification and failure reporting.
        /// </summary>
        internal static FirewallRuleState GetStoredRuleState()
        {
            object policyObject = null;
            object rulesObject = null;
            FirewallRuleState state = new FirewallRuleState();
            bool metadataConsistent = true;

            try
            {
                policyObject = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true));
                dynamic policy = policyObject;
                rulesObject = policy.Rules;
                dynamic rules = rulesObject;

                for (int index = 0; index < AppConfig.RuleNames.Length; index++)
                {
                    object ruleObject = null;
                    try
                    {
                        ruleObject = rules.Item(AppConfig.RuleNames[index]);
                        state.Found++;
                        dynamic rule = ruleObject;
                        string expectedInterface = index < 2 ? "Lan" : "Wireless";
                        bool expectedIpv6 = index % 2 == 1;
                        string addresses = Convert.ToString(rule.RemoteAddresses) ?? string.Empty;
                        string description = Convert.ToString(rule.Description) ?? string.Empty;
                        IPAddress[] metadataAddresses;
                        string canonicalMetadata;
                        bool metadataValid = TryReadAllowedServerMetadata(
                            description,
                            out metadataAddresses,
                            out canonicalMetadata);
                        string expectedAddresses = expectedIpv6
                            ? "::/1,8000::/1"
                            : metadataValid ? BuildIpv4Complement(metadataAddresses) : string.Empty;
                        bool addressesValid = metadataValid &&
                            AddressListsEquivalent(addresses, expectedAddresses);

                        if ((bool)rule.Enabled &&
                            Convert.ToInt32(rule.Direction) == DirectionOutbound &&
                            Convert.ToInt32(rule.Action) == ActionBlock &&
                            Convert.ToInt32(rule.Protocol) == ProtocolAny &&
                            string.Equals(Convert.ToString(rule.Grouping), AppConfig.RuleGroup, StringComparison.Ordinal) &&
                            string.Equals(Convert.ToString(rule.InterfaceTypes), expectedInterface, StringComparison.OrdinalIgnoreCase) &&
                            string.Equals(Convert.ToString(rule.LocalAddresses), "*", StringComparison.Ordinal) &&
                            Convert.ToInt32(rule.Profiles) == AllProfiles &&
                            addressesValid)
                        {
                            state.Valid++;
                            if (state.AllowedServerMetadata == null)
                                state.AllowedServerMetadata = canonicalMetadata;
                            else if (!string.Equals(
                                state.AllowedServerMetadata,
                                canonicalMetadata,
                                StringComparison.Ordinal))
                                metadataConsistent = false;
                        }
                    }
                    catch (Exception ex)
                    {
                        if (!IsMissingRule(ex)) throw;
                    }
                    finally
                    {
                        Release(ruleObject);
                    }
                }
            }
            finally
            {
                Release(rulesObject);
                Release(policyObject);
            }

            if (!metadataConsistent)
            {
                state.Valid = 0;
                state.AllowedServerMetadata = null;
            }

            return state;
        }

        internal static void CreateRules(IPAddress[] allowedServers)
        {
            AssertFirewallAvailable();
            string blockedIpv4 = BuildIpv4Complement(allowedServers);
            string description = AppConfig.RuleDescriptionPrefix +
                BuildAllowedServerMetadata(allowedServers);

            try
            {
                RemoveRules();
                AddRule(AppConfig.RuleNames[0], "Lan", blockedIpv4, description);
                AddRule(AppConfig.RuleNames[1], "Lan", "::/1,8000::/1", description);
                AddRule(AppConfig.RuleNames[2], "Wireless", blockedIpv4, description);
                AddRule(AppConfig.RuleNames[3], "Wireless", "::/1,8000::/1", description);

                DateTime deadline = DateTime.UtcNow.AddSeconds(3);
                do
                {
                    FirewallRuleState state = GetRuleState();
                    if (state.Valid == AppConfig.RuleNames.Length) return;
                    Thread.Sleep(150);
                }
                while (DateTime.UtcNow < deadline);

                throw new InvalidOperationException("Windows did not activate all four kill-switch firewall rules.");
            }
            catch (Exception setupFailure)
            {
                try
                {
                    RemoveRules();
                }
                catch (Exception cleanupFailure)
                {
                    throw new InvalidOperationException(
                        "Kill-switch setup failed and Windows could not remove every partial rule. " +
                        "Internet may be blocked. Use DISCONNECT + UNLOCK or Emergency Unlock.",
                        new AggregateException(setupFailure, cleanupFailure));
                }

                throw new InvalidOperationException(
                    "Kill-switch setup failed. Partial firewall changes were removed and no VPN connection was changed.",
                    setupFailure);
            }
        }

        internal static void RemoveRules()
        {
            object policyObject = null;
            object rulesObject = null;

            try
            {
                policyObject = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true));
                dynamic policy = policyObject;
                rulesObject = policy.Rules;
                dynamic rules = rulesObject;

                foreach (string name in AppConfig.RuleNames)
                {
                    try { rules.Remove(name); }
                    catch (Exception ex)
                    {
                        if (!IsMissingRule(ex)) throw;
                    }
                }
            }
            finally
            {
                Release(rulesObject);
                Release(policyObject);
            }

            FirewallRuleState remaining = GetStoredRuleState();
            if (remaining.Found != 0)
                throw new InvalidOperationException("Windows did not remove every Switzerland kill-switch rule.");
        }

        private static void AddRule(
            string name,
            string interfaceType,
            string remoteAddresses,
            string description)
        {
            object policyObject = null;
            object rulesObject = null;
            object ruleObject = null;

            try
            {
                policyObject = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true));
                dynamic policy = policyObject;
                rulesObject = policy.Rules;
                dynamic rules = rulesObject;

                ruleObject = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule", true));
                dynamic rule = ruleObject;
                rule.Name = name;
                rule.Description = description;
                rule.Grouping = AppConfig.RuleGroup;
                rule.Protocol = ProtocolAny;
                rule.LocalAddresses = "*";
                rule.RemoteAddresses = remoteAddresses;
                rule.Direction = DirectionOutbound;
                rule.InterfaceTypes = interfaceType;
                rule.Profiles = AllProfiles;
                rule.Action = ActionBlock;
                rule.Enabled = true;
                rules.Add(rule);
            }
            finally
            {
                Release(ruleObject);
                Release(rulesObject);
                Release(policyObject);
            }
        }

        private static string BuildIpv4Complement(IPAddress[] addresses)
        {
            ulong[] allowed = addresses
                .Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                .Select(ToUInt32)
                .Distinct()
                .OrderBy(v => v)
                .ToArray();

            if (allowed.Length == 0)
                throw new InvalidOperationException("The Switzerland server did not resolve to a usable IPv4 address.");

            List<string> ranges = new List<string>();
            ulong start = 0;
            foreach (ulong address in allowed)
            {
                if (start < address)
                    ranges.Add(FormatRange(start, address - 1));
                start = address + 1;
            }

            if (start <= uint.MaxValue)
                ranges.Add(FormatRange(start, uint.MaxValue));

            return string.Join(",", ranges);
        }

        private static ulong ToUInt32(IPAddress address)
        {
            byte[] b = address.GetAddressBytes();
            return ((ulong)b[0] << 24) | ((ulong)b[1] << 16) | ((ulong)b[2] << 8) | b[3];
        }

        private static string FromUInt32(ulong value)
        {
            return string.Format("{0}.{1}.{2}.{3}",
                (value >> 24) & 255,
                (value >> 16) & 255,
                (value >> 8) & 255,
                value & 255);
        }

        private static string FormatRange(ulong start, ulong end)
        {
            return start == end ? FromUInt32(start) : FromUInt32(start) + "-" + FromUInt32(end);
        }

        /// <summary>
        /// Creates stable metadata used to prove that each block rule is the exact complement of
        /// the same finite set of allowed VPN-server addresses.
        /// </summary>
        private static string BuildAllowedServerMetadata(IEnumerable<IPAddress> addresses)
        {
            return string.Join(",", addresses
                .Where(a => a != null &&
                    a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                .Select(a => new { Address = a, Numeric = ToUInt32(a) })
                .OrderBy(item => item.Numeric)
                .Select(item => item.Address.ToString())
                .Distinct(StringComparer.Ordinal)
                .ToArray());
        }

        private static bool TryReadAllowedServerMetadata(
            string description,
            out IPAddress[] addresses,
            out string canonicalMetadata)
        {
            addresses = new IPAddress[0];
            canonicalMetadata = null;
            if (string.IsNullOrEmpty(description) ||
                !description.StartsWith(AppConfig.RuleDescriptionPrefix, StringComparison.Ordinal))
                return false;

            string value = description.Substring(AppConfig.RuleDescriptionPrefix.Length);
            try
            {
                addresses = NetworkSafety.ParseValidatedIpv4List(value);
                canonicalMetadata = BuildAllowedServerMetadata(addresses);
                return canonicalMetadata.Length > 0 &&
                    string.Equals(value, canonicalMetadata, StringComparison.Ordinal);
            }
            catch
            {
                addresses = new IPAddress[0];
                canonicalMetadata = null;
                return false;
            }
        }

        private static bool AddressListsEquivalent(string actual, string expected)
        {
            string[] actualTokens = SplitAddressList(actual);
            string[] expectedTokens = SplitAddressList(expected);
            return actualTokens.SequenceEqual(expectedTokens, StringComparer.OrdinalIgnoreCase);
        }

        private static string[] SplitAddressList(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return new string[0];
            return value.Split(',')
                .Select(token => token.Trim())
                .Where(token => token.Length > 0)
                .OrderBy(token => token, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }

        private static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                try { Marshal.FinalReleaseComObject(value); }
                catch { }
            }
        }

        private static bool IsMissingRule(Exception ex)
        {
            return ex.HResult == unchecked((int)0x80070002) ||
                   ex.HResult == unchecked((int)0x80070490);
        }
    }

    internal static class NetworkSafety
    {
        private static readonly Regex NordVpnHostnamePattern = new Regex(
            @"^[a-z]{2}[0-9]+\.nordvpn\.com$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex SwissNordVpnHostnamePattern = new Regex(
            @"^ch[0-9]+\.nordvpn\.com$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        /// <summary>Returns whether a hostname is an official numbered NordVPN endpoint.</summary>
        internal static bool IsNordVpnHostname(string host)
        {
            return !string.IsNullOrWhiteSpace(host) && NordVpnHostnamePattern.IsMatch(host.Trim());
        }

        /// <summary>Returns whether a hostname is an official numbered Swiss NordVPN endpoint.</summary>
        internal static bool IsSwissNordVpnHostname(string host)
        {
            return !string.IsNullOrWhiteSpace(host) && SwissNordVpnHostnamePattern.IsMatch(host.Trim());
        }

        /// <summary>
        /// Normalizes and validates a user-selected NordVPN hostname without performing network I/O.
        /// Swiss-only mode rejects non-Swiss prefixes before any privileged change begins.
        /// </summary>
        internal static string NormalizeServerHostname(string host, bool allowAnyNordVpnServer)
        {
            string normalized = (host ?? string.Empty).Trim().ToLowerInvariant();
            if (!IsNordVpnHostname(normalized))
                throw new InvalidOperationException(
                    "Enter an official NordVPN hostname such as ch221.nordvpn.com or us1234.nordvpn.com.");
            if (!allowAnyNordVpnServer && !IsSwissNordVpnHostname(normalized))
                throw new InvalidOperationException(
                    "Swiss-only mode accepts ch<number>.nordvpn.com servers. Enable Any NordVPN to use another country.");
            return normalized;
        }
        internal static void AssertSupportedEgress()
        {
            List<string> unsupported = new List<string>();
            bool hasActiveRasConnection = RasManager.GetConnections().Count > 0;
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != OperationalStatus.Up || !CanCarryEgress(adapter)) continue;

                int type = (int)adapter.NetworkInterfaceType;
                bool handled =
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Ethernet ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.FastEthernetFx ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.FastEthernetT ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet;

                bool harmless = adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback;
                // An active Windows RAS VPN normally appears as PPP. It is safe to classify
                // temporarily because the kill switch is armed before every non-managed RAS
                // handle is disconnected and verified gone. Non-RAS tunnel adapters still fail.
                bool activeRasVpn = adapter.NetworkInterfaceType == NetworkInterfaceType.Ppp &&
                    hasActiveRasConnection;

                if (!handled && !harmless && !activeRasVpn)
                    unsupported.Add(adapter.Name + " (type " + type + ")");
            }

            if (unsupported.Count > 0)
                throw new InvalidOperationException(
                    "The kill switch cannot safely classify this active internet adapter. " +
                    "Disconnect it before arming Switzerland:\r\n\r\n" + string.Join("\r\n", unsupported));
        }

        internal static IPAddress[] ResolveAndValidateServer(string host)
        {
            string normalizedHost = NormalizeServerHostname(host, true);

            IPAddress[] addresses;
            try
            {
                addresses = Dns.GetHostAddresses(normalizedHost)
                    .Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                    .Where(IsPublicIpv4)
                    .Distinct()
                    .ToArray();
            }
            catch (System.Net.Sockets.SocketException ex)
            {
                throw new InvalidOperationException(
                    "Windows could not look up the Switzerland VPN server. Check that normal internet and DNS work, " +
                    "then try again. The kill switch was not changed.",
                    ex);
            }

            if (addresses.Length == 0)
                throw new InvalidOperationException("Could not resolve " + host + " to a public IPv4 address. The kill switch was not changed.");

            return addresses;
        }

        internal static IPAddress[] ParseValidatedIpv4List(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
                throw new InvalidOperationException("No VPN server addresses were supplied to the firewall helper.");

            List<IPAddress> addresses = new List<IPAddress>();
            foreach (string token in value.Split(','))
            {
                IPAddress address;
                if (!IPAddress.TryParse(token.Trim(), out address) ||
                    address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                    !IsPublicIpv4(address))
                {
                    throw new InvalidOperationException("The firewall helper received an invalid public IPv4 address.");
                }
                addresses.Add(address);
            }

            return addresses.Distinct().ToArray();
        }

        /// <summary>
        /// Treats an active adapter as a possible egress path when it has either a gateway or a
        /// usable non-link-local address. Route-based tunnel and cellular adapters often omit a
        /// conventional gateway, so gateway-only classification would let an unsupported path pass.
        /// </summary>
        private static bool CanCarryEgress(NetworkInterface adapter)
        {
            try
            {
                IPInterfaceProperties properties = adapter.GetIPProperties();
                if (properties.GatewayAddresses.Any(g =>
                    g.Address != null &&
                    !IPAddress.Any.Equals(g.Address) &&
                    !IPAddress.IPv6Any.Equals(g.Address)))
                    return true;

                return properties.UnicastAddresses.Any(unicast =>
                {
                    IPAddress address = unicast.Address;
                    if (address == null || IPAddress.Any.Equals(address) ||
                        IPAddress.Loopback.Equals(address) || IPAddress.IPv6Any.Equals(address) ||
                        IPAddress.IPv6None.Equals(address) || IPAddress.IPv6Loopback.Equals(address))
                        return false;
                    if (address.AddressFamily == AddressFamily.InterNetwork)
                    {
                        byte[] bytes = address.GetAddressBytes();
                        return bytes.Length == 4 && !(bytes[0] == 169 && bytes[1] == 254);
                    }
                    return address.AddressFamily == AddressFamily.InterNetworkV6 &&
                        !address.IsIPv6LinkLocal && !address.IsIPv6Multicast;
                });
            }
            catch (NetworkInformationException)
            {
                return true;
            }
        }

        internal static bool IsPublicIpv4(IPAddress address)
        {
            byte[] b = address.GetAddressBytes();
            if (b.Length != 4) return false;
            if (b[0] == 10 || b[0] == 127 || b[0] == 0) return false;
            if (b[0] == 169 && b[1] == 254) return false;
            if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
            if (b[0] == 192 && b[1] == 168) return false;
            if (b[0] >= 224) return false;
            return true;
        }

        internal static bool IsPublicIpv6(IPAddress address)
        {
            if (address == null || address.AddressFamily != AddressFamily.InterNetworkV6 ||
                IPAddress.IPv6Any.Equals(address) || IPAddress.IPv6None.Equals(address) ||
                IPAddress.IPv6Loopback.Equals(address) || address.IsIPv6LinkLocal ||
                address.IsIPv6Multicast || address.IsIPv6SiteLocal)
                return false;

            byte[] bytes = address.GetAddressBytes();
            return bytes.Length == 16 && (bytes[0] & 0xFE) != 0xFC;
        }
    }

    internal enum PublicAddressProbeStatus
    {
        NotRun,
        Success,
        Timeout,
        Cancelled,
        Unavailable,
        InvalidResponse
    }

    internal enum ManagedRouteState
    {
        NotChecked,
        ViaManagedTunnel,
        BypassRoute,
        Unavailable
    }

    internal enum LeakCheckState
    {
        Disabled,
        WaitingForProtection,
        Checking,
        NoLeakSignals,
        ExposureDetected,
        CheckIncomplete
    }

    internal sealed class PublicAddressProbeResult
    {
        internal readonly PublicAddressProbeStatus Status;
        internal readonly IPAddress Address;
        internal readonly bool HttpResponseReceived;

        internal PublicAddressProbeResult(PublicAddressProbeStatus status, IPAddress address)
            : this(status, address, status == PublicAddressProbeStatus.Success)
        {
        }

        internal PublicAddressProbeResult(
            PublicAddressProbeStatus status,
            IPAddress address,
            bool httpResponseReceived)
        {
            Status = status;
            Address = address;
            HttpResponseReceived = httpResponseReceived;
        }
    }

    internal sealed class LeakProbeConfiguration
    {
        internal readonly Uri Ipv4Endpoint;
        internal readonly Uri Ipv6Endpoint;
        internal readonly TimeSpan RequestTimeout;
        internal readonly int MaximumResponseBytes;

        internal LeakProbeConfiguration(
            Uri ipv4Endpoint,
            Uri ipv6Endpoint,
            TimeSpan requestTimeout,
            int maximumResponseBytes)
        {
            Ipv4Endpoint = ipv4Endpoint;
            Ipv6Endpoint = ipv6Endpoint;
            RequestTimeout = requestTimeout;
            MaximumResponseBytes = maximumResponseBytes;
        }
    }

    internal sealed class LeakProbeSweepResult
    {
        internal readonly ManagedRouteState RouteBefore;
        internal readonly ManagedRouteState RouteAfter;
        internal readonly PublicAddressProbeResult Ipv4;
        internal readonly PublicAddressProbeResult Ipv6;

        internal LeakProbeSweepResult(
            ManagedRouteState routeBefore,
            ManagedRouteState routeAfter,
            PublicAddressProbeResult ipv4,
            PublicAddressProbeResult ipv6)
        {
            RouteBefore = routeBefore;
            RouteAfter = routeAfter;
            Ipv4 = ipv4;
            Ipv6 = ipv6;
        }
    }

    internal sealed class LeakMonitorSnapshot
    {
        internal readonly LeakCheckState State;
        internal readonly ManagedRouteState RouteState;
        internal readonly PublicAddressProbeStatus Ipv4Status;
        internal readonly PublicAddressProbeStatus Ipv6Status;
        internal readonly bool Ipv4ResponseReceived;
        internal readonly bool Ipv6ResponseReceived;
        internal readonly DateTime ObservedUtc;

        internal LeakMonitorSnapshot(
            LeakCheckState state,
            ManagedRouteState routeState,
            PublicAddressProbeStatus ipv4Status,
            PublicAddressProbeStatus ipv6Status,
            bool ipv4ResponseReceived,
            bool ipv6ResponseReceived,
            DateTime observedUtc)
        {
            State = state;
            RouteState = routeState;
            Ipv4Status = ipv4Status;
            Ipv6Status = ipv6Status;
            Ipv4ResponseReceived = ipv4ResponseReceived;
            Ipv6ResponseReceived = ipv6ResponseReceived;
            ObservedUtc = observedUtc;
        }

        internal static LeakMonitorSnapshot Create(LeakCheckState state)
        {
            return new LeakMonitorSnapshot(
                state,
                ManagedRouteState.NotChecked,
                PublicAddressProbeStatus.NotRun,
                PublicAddressProbeStatus.NotRun,
                false,
                false,
                DateTime.UtcNow);
        }

        /// <summary>
        /// Reduces route and public-address observations to one conservative display state. A failed
        /// IPv6 request is only "no response"; it is never treated as proof that leakage is impossible.
        /// </summary>
        internal static LeakMonitorSnapshot FromSweep(LeakProbeSweepResult sweep)
        {
            ManagedRouteState routeState = sweep.RouteBefore == ManagedRouteState.BypassRoute &&
                sweep.RouteAfter == ManagedRouteState.BypassRoute
                    ? ManagedRouteState.BypassRoute
                    : sweep.RouteBefore == ManagedRouteState.ViaManagedTunnel &&
                      sweep.RouteAfter == ManagedRouteState.ViaManagedTunnel
                        ? ManagedRouteState.ViaManagedTunnel
                        : ManagedRouteState.Unavailable;

            bool ipv4Exposure = sweep.Ipv4.HttpResponseReceived &&
                routeState == ManagedRouteState.BypassRoute;
            bool ipv6Exposure = sweep.Ipv6.HttpResponseReceived;
            LeakCheckState state;
            if (ipv4Exposure || ipv6Exposure)
            {
                state = LeakCheckState.ExposureDetected;
            }
            else if (sweep.Ipv4.Status == PublicAddressProbeStatus.Success &&
                routeState == ManagedRouteState.ViaManagedTunnel)
            {
                state = LeakCheckState.NoLeakSignals;
            }
            else
            {
                state = LeakCheckState.CheckIncomplete;
            }

            return new LeakMonitorSnapshot(
                state,
                routeState,
                sweep.Ipv4.Status,
                sweep.Ipv6.Status,
                sweep.Ipv4.HttpResponseReceived,
                sweep.Ipv6.HttpResponseReceived,
                DateTime.UtcNow);
        }
    }

    /// <summary>
    /// Compares the exact RAS-derived interface index with Windows' selected interface for every
    /// resolved probe destination. Checking the route avoids guessing from public-IP geography.
    /// </summary>
    internal static class NetworkRouteProbe
    {
        private const uint ErrorSuccess = 0;
        private const short AddressFamilyIpv4 = 2;
        private const short AddressFamilyIpv6 = 23;

        [DllImport("iphlpapi.dll")]
        private static extern uint GetBestInterfaceEx(
            IntPtr destinationAddress,
            out uint bestInterfaceIndex);

        internal static ManagedRouteState Inspect(IPAddress[] destinations, uint expectedInterfaceIndex)
        {
            if (expectedInterfaceIndex == 0 || destinations == null || destinations.Length == 0)
                return ManagedRouteState.Unavailable;

            bool inspectedAny = false;
            foreach (IPAddress destination in destinations)
            {
                if (destination == null) continue;
                IntPtr socketAddress = IntPtr.Zero;
                try
                {
                    socketAddress = CreateSocketAddress(destination);
                    uint bestInterfaceIndex;
                    if (GetBestInterfaceEx(socketAddress, out bestInterfaceIndex) != ErrorSuccess ||
                        bestInterfaceIndex == 0)
                        return ManagedRouteState.Unavailable;
                    inspectedAny = true;
                    if (bestInterfaceIndex != expectedInterfaceIndex)
                        return ManagedRouteState.BypassRoute;
                }
                finally
                {
                    if (socketAddress != IntPtr.Zero) Marshal.FreeHGlobal(socketAddress);
                }
            }

            return inspectedAny
                ? ManagedRouteState.ViaManagedTunnel
                : ManagedRouteState.Unavailable;
        }

        private static IntPtr CreateSocketAddress(IPAddress address)
        {
            byte[] addressBytes = address.GetAddressBytes();
            bool ipv4 = address.AddressFamily == AddressFamily.InterNetwork;
            bool ipv6 = address.AddressFamily == AddressFamily.InterNetworkV6;
            if (!ipv4 && !ipv6)
                throw new ArgumentException("Only IPv4 and IPv6 destinations are supported.", "address");

            int size = ipv4 ? 16 : 28;
            int addressOffset = ipv4 ? 4 : 8;
            IntPtr socketAddress = Marshal.AllocHGlobal(size);
            for (int offset = 0; offset < size; offset++) Marshal.WriteByte(socketAddress, offset, 0);
            Marshal.WriteInt16(socketAddress, 0, ipv4 ? AddressFamilyIpv4 : AddressFamilyIpv6);
            Marshal.Copy(addressBytes, 0, IntPtr.Add(socketAddress, addressOffset), addressBytes.Length);
            if (ipv6 && address.ScopeId > 0)
                Marshal.WriteInt32(socketAddress, 24, checked((int)address.ScopeId));
            return socketAddress;
        }
    }

    /// <summary>
    /// Runs bounded, proxy-disabled HTTPS probes against ipify's documented IPv4-only and
    /// IPv6-only endpoints. Responses are capped and accepted only when they contain one public IP.
    /// </summary>
    internal static class PublicIpLeakProbe
    {
        private static readonly LeakProbeConfiguration Configuration = new LeakProbeConfiguration(
            new Uri("https://api.ipify.org/", UriKind.Absolute),
            new Uri("https://api6.ipify.org/", UriKind.Absolute),
            TimeSpan.FromSeconds(4),
            64);
        private static readonly object DnsLookupSync = new object();
        private static readonly Dictionary<string, Task<IPAddress[]>> PendingDnsLookups =
            new Dictionary<string, Task<IPAddress[]>>(StringComparer.OrdinalIgnoreCase);

        static PublicIpLeakProbe()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        }

        internal static LeakProbeSweepResult Run(uint expectedInterfaceIndex, CancellationToken cancellationToken)
        {
            IPAddress[] ipv4Destinations = ResolveEndpoint(
                Configuration.Ipv4Endpoint,
                AddressFamily.InterNetwork,
                Configuration.RequestTimeout,
                cancellationToken);
            ManagedRouteState routeBefore = NetworkRouteProbe.Inspect(
                ipv4Destinations,
                expectedInterfaceIndex);

            Task<PublicAddressProbeResult> ipv4Task = QueryAddressAsync(
                Configuration.Ipv4Endpoint,
                AddressFamily.InterNetwork,
                cancellationToken);
            Task<PublicAddressProbeResult> ipv6Task = QueryAddressAsync(
                Configuration.Ipv6Endpoint,
                AddressFamily.InterNetworkV6,
                cancellationToken);
            Task.WaitAll(new Task[] { ipv4Task, ipv6Task });

            ManagedRouteState routeAfter = NetworkRouteProbe.Inspect(
                ipv4Destinations,
                expectedInterfaceIndex);
            return new LeakProbeSweepResult(
                routeBefore,
                routeAfter,
                ipv4Task.Result,
                ipv6Task.Result);
        }

        /// <summary>
        /// Resolves probe routes without letting synchronous name service stall the monitor worker.
        /// The platform lookup itself cannot be cancelled on this target framework, so the caller
        /// stops waiting at the deadline and treats the route check as unavailable.
        /// </summary>
        private static IPAddress[] ResolveEndpoint(
            Uri endpoint,
            AddressFamily family,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                Task<IPAddress[]> lookup = GetOrStartDnsLookup(endpoint.DnsSafeHost);
                Task deadline = Task.Delay(timeout, cancellationToken);
                Task completed = Task.WhenAny(lookup, deadline).GetAwaiter().GetResult();
                if (!ReferenceEquals(completed, lookup))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    return new IPAddress[0];
                }

                return lookup.GetAwaiter().GetResult()
                    .Where(address => address.AddressFamily == family)
                    .Where(address => family == AddressFamily.InterNetwork
                        ? NetworkSafety.IsPublicIpv4(address)
                        : NetworkSafety.IsPublicIpv6(address))
                    .Distinct()
                    .ToArray();
            }
            catch (SocketException)
            {
                return new IPAddress[0];
            }
        }

        /// <summary>
        /// Reuses one unresolved lookup per host so repeated monitor sweeps cannot accumulate an
        /// unbounded queue when the platform DNS operation itself fails to return.
        /// </summary>
        private static Task<IPAddress[]> GetOrStartDnsLookup(string host)
        {
            lock (DnsLookupSync)
            {
                Task<IPAddress[]> existing;
                if (PendingDnsLookups.TryGetValue(host, out existing) && !existing.IsCompleted)
                    return existing;

                Task<IPAddress[]> lookup = Dns.GetHostAddressesAsync(host);
                PendingDnsLookups[host] = lookup;
                lookup.ContinueWith(
                    completed =>
                    {
                        lock (DnsLookupSync)
                        {
                            Task<IPAddress[]> current;
                            if (PendingDnsLookups.TryGetValue(host, out current) &&
                                ReferenceEquals(current, completed))
                                PendingDnsLookups.Remove(host);
                        }
                        if (completed.IsFaulted)
                        {
                            AggregateException ignored = completed.Exception;
                            GC.KeepAlive(ignored);
                        }
                    },
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
                return lookup;
            }
        }

        private static async Task<PublicAddressProbeResult> QueryAddressAsync(
            Uri endpoint,
            AddressFamily expectedFamily,
            CancellationToken cancellationToken)
        {
            using (HttpClientHandler handler = new HttpClientHandler
            {
                AllowAutoRedirect = false,
                UseProxy = false,
                AutomaticDecompression = DecompressionMethods.None
            })
            using (HttpClient client = new HttpClient(handler)
            {
                Timeout = System.Threading.Timeout.InfiniteTimeSpan,
                MaxResponseContentBufferSize = Configuration.MaximumResponseBytes + 1
            })
            using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, endpoint))
            using (CancellationTokenSource requestCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                requestCancellation.CancelAfter(Configuration.RequestTimeout);
                CancellationToken requestToken = requestCancellation.Token;
                request.Headers.TryAddWithoutValidation(
                    "User-Agent",
                    "Switzerland-VPN/" + AppConfig.CurrentVersion + " leak-monitor");
                request.Headers.TryAddWithoutValidation("Cache-Control", "no-cache, no-store");
                bool responseReceived = false;
                try
                {
                    using (HttpResponseMessage response = await client.SendAsync(
                        request,
                        HttpCompletionOption.ResponseHeadersRead,
                        requestToken).ConfigureAwait(false))
                    {
                        responseReceived = true;
                        if (response.StatusCode != HttpStatusCode.OK)
                            return new PublicAddressProbeResult(
                                PublicAddressProbeStatus.InvalidResponse,
                                null,
                                true);
                        if (response.Content.Headers.ContentLength.HasValue &&
                            response.Content.Headers.ContentLength.Value > Configuration.MaximumResponseBytes)
                            return new PublicAddressProbeResult(
                                PublicAddressProbeStatus.InvalidResponse,
                                null,
                                true);

                        using (Stream responseStream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        {
                            byte[] buffer = new byte[Configuration.MaximumResponseBytes + 1];
                            int total = 0;
                            while (total < buffer.Length)
                            {
                                int read = await responseStream.ReadAsync(
                                    buffer,
                                    total,
                                    buffer.Length - total,
                                    requestToken).ConfigureAwait(false);
                                if (read == 0) break;
                                total += read;
                            }
                            if (total == 0 || total > Configuration.MaximumResponseBytes)
                                return new PublicAddressProbeResult(
                                    PublicAddressProbeStatus.InvalidResponse,
                                    null,
                                    true);

                            string value = Encoding.ASCII.GetString(buffer, 0, total).Trim();
                            IPAddress address;
                            bool valid = IPAddress.TryParse(value, out address) &&
                                address.AddressFamily == expectedFamily &&
                                (expectedFamily == AddressFamily.InterNetwork
                                    ? NetworkSafety.IsPublicIpv4(address)
                                    : NetworkSafety.IsPublicIpv6(address));
                            return valid
                                ? new PublicAddressProbeResult(PublicAddressProbeStatus.Success, address)
                                : new PublicAddressProbeResult(
                                    PublicAddressProbeStatus.InvalidResponse,
                                    null,
                                    true);
                        }
                    }
                }
                catch (TaskCanceledException)
                {
                    return new PublicAddressProbeResult(
                        cancellationToken.IsCancellationRequested
                            ? PublicAddressProbeStatus.Cancelled
                            : PublicAddressProbeStatus.Timeout,
                        null,
                        responseReceived);
                }
                catch (HttpRequestException)
                {
                    return new PublicAddressProbeResult(
                        PublicAddressProbeStatus.Unavailable,
                        null,
                        responseReceived);
                }
                catch (IOException)
                {
                    return new PublicAddressProbeResult(
                        PublicAddressProbeStatus.Unavailable,
                        null,
                        responseReceived);
                }
            }
        }
    }

    internal sealed class VpnForm : Form
    {
        private sealed class WidgetLayout
        {
            internal readonly Size ClientSize = new Size(418, 409);
            internal readonly Rectangle Title = new Rectangle(33, 24, 352, 31);
            internal readonly Rectangle StatusPrefix = new Rectangle(33, 60, 61, 23);
            internal readonly Rectangle Status = new Rectangle(101, 60, 284, 23);
            internal readonly Rectangle Detail = new Rectangle(33, 86, 352, 21);
            internal readonly Rectangle Connect = new Rectangle(33, 112, 169, 40);
            internal readonly Rectangle Disconnect = new Rectangle(216, 112, 169, 40);
            internal readonly Rectangle ConnectOnly = new Rectangle(33, 158, 81, 25);
            internal readonly Rectangle ArmOnly = new Rectangle(121, 158, 81, 25);
            internal readonly Rectangle DisconnectOnly = new Rectangle(216, 158, 81, 25);
            internal readonly Rectangle UnlockOnly = new Rectangle(304, 158, 81, 25);
            internal readonly Rectangle ServerLabel = new Rectangle(33, 190, 53, 25);
            internal readonly Rectangle Server = new Rectangle(86, 190, 211, 25);
            internal readonly Rectangle ApplyServer = new Rectangle(304, 190, 81, 25);
            internal readonly Rectangle AnyNordVpn = new Rectangle(33, 216, 145, 22);
            internal readonly Rectangle CurrentServer = new Rectangle(184, 216, 201, 22);
            internal readonly Rectangle AlwaysOnTop = new Rectangle(33, 236, 110, 30);
            internal readonly Rectangle Monitor = new Rectangle(154, 236, 110, 30);
            internal readonly Rectangle Refresh = new Rectangle(275, 236, 110, 30);
            internal readonly Rectangle SignIn = new Rectangle(33, 272, 169, 30);
            internal readonly Rectangle ClearCredentials = new Rectangle(216, 272, 169, 30);
            internal readonly Rectangle Telemetry = new Rectangle(33, 309, 352, 19);
            internal readonly Rectangle Route = new Rectangle(33, 329, 352, 19);
            internal readonly Rectangle Leak = new Rectangle(33, 349, 352, 19);
            internal readonly Rectangle Version = new Rectangle(33, 370, 48, 18);
            internal readonly Rectangle Update = new Rectangle(88, 370, 114, 18);
            internal readonly Rectangle Footer = new Rectangle(216, 370, 169, 18);
        }

        private sealed class VpnActionRequest
        {
            internal Action Execute;
            internal VpnOperation Operation;
            internal string SuccessMessage;
        }

        private sealed class TrafficCounterSample
        {
            internal IntPtr ConnectionHandle;
            internal uint BytesSent;
            internal uint BytesReceived;
            internal uint ConnectDurationMilliseconds;
            internal long Timestamp;
        }

        private sealed class UpdaterHandoffResult
        {
            internal bool Ready;
            internal string FailureMessage;
        }

        private static readonly Color ConnectButtonColor = Color.FromArgb(27, 139, 93);
        private static readonly Color DisconnectButtonColor = Color.FromArgb(177, 63, 68);
        private static readonly Color DisabledButtonColor = Color.FromArgb(63, 67, 76);
        private static readonly WidgetLayout Grid = new WidgetLayout();
        private readonly Image themeBackground;
        private readonly Label statusPrefix;
        private readonly Label statusLabel;
        private readonly Label detailLabel;
        private readonly Label telemetryLabel;
        private readonly Label routeLabel;
        private readonly Label leakLabel;
        private readonly Button connectButton;
        private readonly Button connectOnlyButton;
        private readonly Button armOnlyButton;
        private readonly Button disconnectButton;
        private readonly Button disconnectOnlyButton;
        private readonly Button unlockOnlyButton;
        private readonly Button signInButton;
        private readonly Button clearCredentialsButton;
        private readonly Button refreshButton;
        private readonly Button applyServerButton;
        private readonly ComboBox serverComboBox;
        private readonly CheckBox allowAnyNordVpnCheck;
        private readonly Label currentServerLabel;
        private readonly LinkLabel updateLink;
        private readonly CheckBox topMostCheck;
        private readonly CheckBox monitorCheck;
        private readonly ToolStripMenuItem trayConnectItem;
        private readonly ToolStripMenuItem trayConnectOnlyItem;
        private readonly ToolStripMenuItem trayArmOnlyItem;
        private readonly ToolStripMenuItem trayDisconnectItem;
        private readonly ToolStripMenuItem trayDisconnectOnlyItem;
        private readonly ToolStripMenuItem trayUnlockOnlyItem;
        private readonly ToolStripMenuItem traySignInItem;
        private readonly ToolStripMenuItem trayClearCredentialsItem;
        private readonly ToolStripMenuItem trayUpdateItem;
        private readonly NotifyIcon trayIcon;
        private readonly System.Windows.Forms.Timer timer;
        private readonly ToolTip toolTips;
        private readonly Dictionary<Control, string> controlToolTipText;
        private string lastTrayStatus = "Starting";
        private const int VisibleMonitoringIntervalMilliseconds = 1000;
        private const int BackgroundMonitoringIntervalMilliseconds = 5000;
        private static readonly TimeSpan ProtectionRefreshInterval = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan ProtectionFreshnessWindow = TimeSpan.FromSeconds(7);
        private static readonly TimeSpan ConnectionFreshnessWindow = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan PingInterval = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan PingFreshnessWindow = TimeSpan.FromSeconds(12);
        private static readonly TimeSpan LeakProbeInterval = TimeSpan.FromSeconds(60);
        private readonly object monitoringSync = new object();
        private WidgetState monitoredState;
        private DateTime monitoredStateObservedUtc = DateTime.MinValue;
        private DateTime nextStateRefreshUtc = DateTime.MinValue;
        private TrafficCounterSample previousTrafficSample;
        private double monitoredDownloadMbps;
        private double monitoredUploadMbps;
        private bool monitoredTrafficReady;
        private bool monitoredConnectionVerified;
        private DateTime monitoredConnectionObservedUtc = DateTime.MinValue;
        private bool monitoredPingAvailable;
        private bool monitoredPingSucceeded;
        private long monitoredPingMilliseconds;
        private DateTime monitoredPingObservedUtc = DateTime.MinValue;
        private DateTime nextPingAllowedUtc = DateTime.MinValue;
        private LeakMonitorSnapshot leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.Disabled);
        private DateTime nextLeakProbeAllowedUtc = DateTime.MinValue;
        private CancellationTokenSource leakProbeCancellation;
        private long protectionGeneration;
        private long monitoringEpoch;
        private int monitoringWorkerActive;
        private int pingWorkerActive;
        private int leakProbeWorkerActive;
        private int forceStateRefreshRequested;
        private int monitoringUiUpdatePending;
        private int monitoringStateUiRefreshRequested;
        private long monitoringStateUiRefreshEpoch;
        private volatile bool monitoringEnabled;
        private volatile bool monitoringStopped;
        private volatile bool monitoringPausedForAction;
        private Control lastDisabledToolTipControl;
        private VpnOperation currentOperation = VpnOperation.None;
        private UpdateCheckState updateCheckState = UpdateCheckState.Idle;
        private bool updaterHandoffStarted;
        private readonly WidgetState previewState;

        private bool IsActionRunning
        {
            get { return currentOperation != VpnOperation.None; }
        }

        internal VpnForm(WidgetState preview)
        {
            previewState = preview;
            Text = "Switzerland VPN";
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            ClientSize = Grid.ClientSize;
            themeBackground = LoadThemeBackground(Grid.ClientSize);
            StartPosition = FormStartPosition.Manual;
            MaximizeBox = false;
            MinimizeBox = true;
            BackColor = Color.FromArgb(24, 26, 31);
            ForeColor = Color.WhiteSmoke;
            Font = new Font("Segoe UI", 9f);
            ShowInTaskbar = true;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            controlToolTipText = new Dictionary<Control, string>();
            toolTips = new ToolTip
            {
                AutoPopDelay = 5000,
                InitialDelay = 350,
                ReshowDelay = 100,
                ShowAlways = true
            };
            Label title = new Label
            {
                Text = "SWITZERLAND VPN",
                Font = new Font("Segoe UI Semibold", 14f),
                ForeColor = Color.FromArgb(235, 238, 244),
                BackColor = Color.Transparent,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = Grid.Title
            };
            Controls.Add(title);
            RegisterToolTip(title, "Switzerland VPN controls.");

            statusPrefix = new Label
            {
                Text = "STATUS:",
                Font = new Font("Segoe UI Semibold", 10f),
                BackColor = Color.Transparent,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.StatusPrefix
            };
            Controls.Add(statusPrefix);
            RegisterToolTip(statusPrefix, "Current VPN and kill-switch state.");

            statusLabel = new Label
            {
                Font = new Font("Segoe UI Semibold", 10f),
                BackColor = Color.Transparent,
                AutoSize = false,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.Status
            };
            Controls.Add(statusLabel);
            RegisterToolTip(statusLabel, "Current VPN and kill-switch state.");

            detailLabel = new Label
            {
                ForeColor = Color.FromArgb(170, 176, 188),
                BackColor = Color.Transparent,
                AutoSize = false,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = Grid.Detail
            };
            Controls.Add(detailLabel);
            RegisterToolTip(detailLabel, "A short explanation of the current state.");

            connectButton = NewButton(
                "CONNECT + ARM",
                Grid.Connect.Location,
                ConnectButtonColor,
                Grid.Connect.Size);
            disconnectButton = NewButton(
                "DISCONNECT + UNLOCK",
                Grid.Disconnect.Location,
                DisconnectButtonColor,
                Grid.Disconnect.Size);
            Controls.Add(connectButton);
            Controls.Add(disconnectButton);
            RegisterToolTip(connectButton, "Arm protection, then connect the VPN.");
            RegisterToolTip(disconnectButton, "Disconnect the VPN, then restore normal internet.");

            connectOnlyButton = NewSmallButton(
                "CONNECT", Grid.ConnectOnly.Location, Grid.ConnectOnly.Size, ConnectButtonColor);
            armOnlyButton = NewSmallButton(
                "ARM", Grid.ArmOnly.Location, Grid.ArmOnly.Size, ConnectButtonColor);
            disconnectOnlyButton = NewSmallButton(
                "DISCONNECT", Grid.DisconnectOnly.Location, Grid.DisconnectOnly.Size, DisconnectButtonColor);
            unlockOnlyButton = NewSmallButton(
                "UNLOCK", Grid.UnlockOnly.Location, Grid.UnlockOnly.Size, DisconnectButtonColor);
            Controls.Add(connectOnlyButton);
            Controls.Add(armOnlyButton);
            Controls.Add(disconnectOnlyButton);
            Controls.Add(unlockOnlyButton);
            RegisterToolTip(connectOnlyButton, "Connect without changing kill-switch protection.");
            RegisterToolTip(armOnlyButton, "Arm protection without connecting. If the VPN dies, normal internet dies with it. Fair is fair.");
            RegisterToolTip(disconnectOnlyButton, "Disconnect without unlocking. Drops the tunnel. The kill switch keeps the internet hostage.");
            RegisterToolTip(unlockOnlyButton, "Remove the kill switch without disconnecting.");

            Label serverLabel = new Label
            {
                Text = "SERVER",
                Font = new Font("Segoe UI Semibold", 8f),
                ForeColor = Color.FromArgb(225, 228, 235),
                BackColor = Color.Transparent,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.ServerLabel
            };
            serverComboBox = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDown,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 8.5f),
                Bounds = Grid.Server,
                MaxDropDownItems = 12
            };
            serverComboBox.Items.AddRange(AppConfig.SwissServerPool.Cast<object>().ToArray());
            serverComboBox.Text = AppConfig.ServerHost;
            applyServerButton = NewSmallButton(
                "APPLY", Grid.ApplyServer.Location, Grid.ApplyServer.Size, Color.FromArgb(55, 89, 144));
            allowAnyNordVpnCheck = new CheckBox
            {
                Text = "Any NordVPN country",
                Checked = ReadAllowAnyNordVpnSetting(),
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.AnyNordVpn,
                ForeColor = Color.FromArgb(184, 190, 201),
                BackColor = Color.Transparent
            };
            currentServerLabel = new Label
            {
                Text = "CURRENT: " + AppConfig.ServerHost,
                Font = new Font("Segoe UI Semibold", 8f),
                ForeColor = Color.FromArgb(184, 190, 201),
                BackColor = Color.Transparent,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleRight,
                Bounds = Grid.CurrentServer
            };
            Controls.Add(serverLabel);
            Controls.Add(serverComboBox);
            Controls.Add(applyServerButton);
            Controls.Add(allowAnyNordVpnCheck);
            Controls.Add(currentServerLabel);
            RegisterToolTip(serverLabel, "The NordVPN server used by the Windows VPN profile and kill switch.");
            RegisterToolTip(serverComboBox, "Choose a Swiss server or type an official NordVPN hostname.");
            RegisterToolTip(applyServerButton, "Validate and apply this server to the VPN profile.");
            RegisterToolTip(
                allowAnyNordVpnCheck,
                "Off accepts Swiss ch servers only. On accepts official numbered NordVPN servers in other countries.");
            RegisterToolTip(currentServerLabel, "The server currently saved in the Windows VPN profile configuration.");

            topMostCheck = new CheckBox
            {
                Text = "Always on top",
                Checked = true,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.AlwaysOnTop,
                ForeColor = Color.FromArgb(225, 228, 235),
                BackColor = Color.Transparent
            };
            Controls.Add(topMostCheck);
            RegisterToolTip(topMostCheck, "Keep this window above other windows.");

            monitorCheck = new CheckBox
            {
                Text = "Live monitor",
                Checked = preview != null,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = Grid.Monitor,
                ForeColor = Color.FromArgb(225, 228, 235),
                BackColor = Color.Transparent
            };
            Controls.Add(monitorCheck);
            RegisterToolTip(
                monitorCheck,
                "Toggle traffic, latency, exact-route, IPv4, and IPv6 leak checks. Off means zero background probes.");

            signInButton = NewButton(
                "SET UP SIGN-IN",
                Grid.SignIn.Location,
                Color.FromArgb(55, 89, 144),
                Grid.SignIn.Size);
            signInButton.Font = new Font("Segoe UI Semibold", 8.5f);
            Controls.Add(signInButton);
            RegisterToolTip(signInButton, "Save the VPN service sign-in.");

            clearCredentialsButton = NewButton(
                "CLEAR SAVED CREDENTIALS",
                Grid.ClearCredentials.Location,
                Color.FromArgb(116, 78, 46),
                Grid.ClearCredentials.Size);
            clearCredentialsButton.Font = new Font("Segoe UI Semibold", 7.5f);
            Controls.Add(clearCredentialsButton);
            RegisterToolTip(clearCredentialsButton, "Clear the saved VPN sign-in. Makes Windows forget the password. Finally, something it's good at.");

            refreshButton = NewButton(
                "REFRESH",
                Grid.Refresh.Location,
                Color.FromArgb(42, 45, 53),
                Grid.Refresh.Size);
            refreshButton.FlatAppearance.BorderSize = 1;
            refreshButton.FlatAppearance.BorderColor = Color.FromArgb(80, 85, 96);
            Controls.Add(refreshButton);
            RegisterToolTip(refreshButton, "Check VPN and firewall protection now.");

            telemetryLabel = new Label
            {
                Text = preview == null
                    ? "MONITOR OFF | CLICK LIVE MONITOR TO START"
                    : "VERIFYING | PING -- | TRAFFIC DOWN -- / UP --",
                ForeColor = preview == null
                    ? Color.FromArgb(132, 139, 151)
                    : Color.FromArgb(239, 75, 79),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI Semibold", 7.75f),
                AutoSize = false,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = Grid.Telemetry
            };
            Controls.Add(telemetryLabel);
            RegisterToolTip(telemetryLabel, "Exact VPN traffic and protected-only latency. Traffic is not a speed test.");

            routeLabel = new Label
            {
                Text = preview == null
                    ? "ROUTE CHECK OFF"
                    : "ROUTE: CHECKING | IPv4: -- | IPv6: --",
                ForeColor = preview == null
                    ? Color.FromArgb(132, 139, 151)
                    : Color.FromArgb(84, 150, 235),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI Semibold", 7.75f),
                AutoSize = false,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = Grid.Route
            };
            Controls.Add(routeLabel);
            RegisterToolTip(
                routeLabel,
                "Checks this IPv4 probe uses the exact VPN. IPv6 isn't tunneled, so enabling it could leak.");

            leakLabel = new Label
            {
                Text = preview == null
                    ? "IP LEAK CHECK OFF"
                    : "IP LEAK CHECK: WAITING",
                ForeColor = preview == null
                    ? Color.FromArgb(132, 139, 151)
                    : Color.FromArgb(84, 150, 235),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI Semibold", 7.75f),
                AutoSize = false,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleCenter,
                Bounds = Grid.Leak
            };
            Controls.Add(leakLabel);
            RegisterToolTip(
                leakLabel,
                "Direct no-proxy IP check via ipify. This app saves no IP history; it does not test DNS or browser WebRTC.");

            Label footer = new Label
            {
                Text = "Justichuu's Swiss Army VPN",
                ForeColor = Color.FromArgb(184, 190, 201),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI", 7.5f),
                TextAlign = ContentAlignment.MiddleRight,
                AutoSize = false,
                Bounds = Grid.Footer
            };
            Controls.Add(footer);
            RegisterToolTip(footer, "Application name.");

            LinkLabel versionLink = new LinkLabel
            {
                Text = "v" + AppConfig.CurrentVersion,
                LinkColor = Color.FromArgb(184, 190, 201),
                ActiveLinkColor = Color.White,
                VisitedLinkColor = Color.FromArgb(184, 190, 201),
                DisabledLinkColor = Color.FromArgb(132, 139, 151),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI", 7.5f),
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                LinkBehavior = LinkBehavior.HoverUnderline,
                Bounds = Grid.Version
            };
            versionLink.LinkClicked += delegate { OpenRepository(); };
            Controls.Add(versionLink);
            RegisterToolTip(versionLink, "Open this project on GitHub.");

            updateLink = new LinkLabel
            {
                Text = "CHECK UPDATE",
                LinkColor = Color.FromArgb(184, 190, 201),
                ActiveLinkColor = Color.White,
                VisitedLinkColor = Color.FromArgb(184, 190, 201),
                DisabledLinkColor = Color.FromArgb(132, 139, 151),
                BackColor = Color.Transparent,
                Font = new Font("Segoe UI", 7.5f),
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                LinkBehavior = LinkBehavior.HoverUnderline,
                Bounds = Grid.Update
            };
            updateLink.LinkClicked += delegate { BeginCheckForUpdate(); };
            Controls.Add(updateLink);
            RegisterToolTip(
                updateLink,
                "Check the latest private GitHub release. Requires GitHub CLI sign-in.");

            ContextMenuStrip trayMenu = new ContextMenuStrip { ShowItemToolTips = true };
            ToolStripMenuItem trayOpenItem = new ToolStripMenuItem("Open Switzerland VPN", null, delegate { RestoreFromTray(); })
            {
                ToolTipText = "Open the VPN controls."
            };
            trayMenu.Items.Add(trayOpenItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            trayConnectItem = new ToolStripMenuItem("Connect + Arm", null, delegate { BeginConnect(); });
            trayDisconnectItem = new ToolStripMenuItem("Disconnect + Unlock", null, delegate { BeginDisconnect(); });
            trayConnectOnlyItem = new ToolStripMenuItem("Connect Only...", null, delegate { BeginConnectOnly(); });
            trayArmOnlyItem = new ToolStripMenuItem("Arm Only...", null, delegate { BeginArmOnly(); });
            trayDisconnectOnlyItem = new ToolStripMenuItem("Disconnect Only...", null, delegate { BeginDisconnectOnly(); });
            trayUnlockOnlyItem = new ToolStripMenuItem("Unlock Only...", null, delegate { BeginUnlockOnly(); });
            traySignInItem = new ToolStripMenuItem("Set Up Sign-In", null, delegate { BeginProtectedSignIn(false); });
            trayClearCredentialsItem = new ToolStripMenuItem("Clear Saved Credentials...", null, delegate { ClearSavedCredentials(); });
            trayUpdateItem = new ToolStripMenuItem("Check for Updates...", null, delegate { BeginCheckForUpdate(); });
            trayConnectItem.ToolTipText = "Arm protection, then connect the VPN.";
            trayDisconnectItem.ToolTipText = "Disconnect the VPN, then restore normal internet.";
            trayConnectOnlyItem.ToolTipText = "Connect without changing kill-switch protection.";
            trayArmOnlyItem.ToolTipText = "Arm protection without connecting. If the VPN dies, normal internet dies with it. Fair is fair.";
            trayDisconnectOnlyItem.ToolTipText = "Disconnect without unlocking. Drops the tunnel. The kill switch keeps the internet hostage.";
            trayUnlockOnlyItem.ToolTipText = "Remove the kill switch without disconnecting.";
            traySignInItem.ToolTipText = "Save the VPN service sign-in.";
            trayClearCredentialsItem.ToolTipText = "Clear the saved VPN sign-in. Makes Windows forget the password. Finally, something it's good at.";
            trayUpdateItem.ToolTipText = "Check the latest private GitHub release. Requires GitHub CLI sign-in.";
            trayMenu.Items.Add(trayConnectItem);
            trayMenu.Items.Add(trayDisconnectItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add(trayConnectOnlyItem);
            trayMenu.Items.Add(trayArmOnlyItem);
            trayMenu.Items.Add(trayDisconnectOnlyItem);
            trayMenu.Items.Add(trayUnlockOnlyItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add(traySignInItem);
            trayMenu.Items.Add(trayClearCredentialsItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add(trayUpdateItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem trayExitItem = new ToolStripMenuItem("Exit", null, delegate { Close(); })
            {
                ToolTipText = "Stop monitoring and close the app."
            };
            trayMenu.Items.Add(trayExitItem);

            trayIcon = new NotifyIcon
            {
                Icon = Icon,
                Text = "Switzerland VPN",
                Visible = preview == null,
                ContextMenuStrip = trayMenu
            };
            trayIcon.MouseDoubleClick += delegate { RestoreFromTray(); };

            timer = new System.Windows.Forms.Timer { Interval = VisibleMonitoringIntervalMilliseconds };
            timer.Tick += delegate
            {
                RefreshTelemetryLabel();
                QueueMonitoringCycle(false);
            };

            connectButton.Click += delegate { BeginConnect(); };
            disconnectButton.Click += delegate { BeginDisconnect(); };
            connectOnlyButton.Click += delegate { BeginConnectOnly(); };
            armOnlyButton.Click += delegate { BeginArmOnly(); };
            disconnectOnlyButton.Click += delegate { BeginDisconnectOnly(); };
            unlockOnlyButton.Click += delegate { BeginUnlockOnly(); };
            signInButton.Click += delegate { BeginProtectedSignIn(false); };
            clearCredentialsButton.Click += delegate { ClearSavedCredentials(); };
            refreshButton.Click += delegate { UpdateStatus(); };
            applyServerButton.Click += delegate { BeginServerChange(); };
            allowAnyNordVpnCheck.CheckedChanged += delegate
            {
                if (previewState == null) SaveAllowAnyNordVpnSetting(allowAnyNordVpnCheck.Checked);
            };
            topMostCheck.CheckedChanged += delegate { TopMost = topMostCheck.Checked; };
            monitorCheck.CheckedChanged += delegate { SetMonitoringEnabled(monitorCheck.Checked); };
            MouseMove += HandleDisabledControlToolTip;
            Resize += HandleResize;
            FormClosing += HandleClosing;
            Shown += delegate
            {
                TopMost = topMostCheck.Checked;
                if (preview == null)
                {
                    Rectangle area = Screen.PrimaryScreen.WorkingArea;
                    Location = new Point(area.Right - Width - 18, area.Bottom - Height - 18);
                    SetMonitoringEnabled(monitorCheck.Checked);
                }
                else
                    UpdateStatus();
            };
        }

        internal void RenderPreview(string outputPath)
        {
            TopMost = false;
            ShowInTaskbar = false;
            Location = new Point(-32000, -32000);
            Show();
            Application.DoEvents();
            UpdateStatus();
            Application.DoEvents();
            using (Bitmap bitmap = new Bitmap(Width, Height))
            {
                DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height));
                bitmap.Save(outputPath, System.Drawing.Imaging.ImageFormat.Png);
            }
            Close();
        }

        private void RegisterToolTip(Control control, string text)
        {
            if (control == null) throw new ArgumentNullException("control");
            if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("Tooltip text is required.", "text");
            controlToolTipText[control] = text;
            toolTips.SetToolTip(control, text);
        }

        private void OpenRepository()
        {
            try
            {
                Process.Start(new ProcessStartInfo(AppConfig.RepositoryUrl) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Could not open the GitHub repository.\r\n\r\n" + ex.Message,
                    "Switzerland VPN",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        /// <summary>
        /// Starts a serialized, non-blocking check of the latest private GitHub release.
        /// GitHub CLI retains and supplies its own credential; this app never reads the token.
        /// </summary>
        private void BeginCheckForUpdate()
        {
            if (IsActionRunning || previewState != null) return;

            currentOperation = VpnOperation.CheckingUpdate;
            updateCheckState = UpdateCheckState.Checking;
            PauseMonitoringForAction();
            ApplyBusyState(currentOperation);
            UseWaitCursor = true;

            ThreadPool.QueueUserWorkItem(delegate
            {
                GitHubReleaseInfo release = null;
                Exception failure = null;
                try { release = PrivateUpdateManager.CheckLatestRelease(); }
                catch (Exception ex) { failure = ex; }

                PostToUi(delegate { CompleteReleaseCheck(release, failure); });
            });
        }

        private void CompleteReleaseCheck(GitHubReleaseInfo release, Exception failure)
        {
            if (failure != null)
            {
                FinishUpdateOperation(UpdateCheckState.Failed);
                MessageBox.Show(
                    string.IsNullOrWhiteSpace(failure.Message)
                        ? "The private update check failed. Nothing was downloaded."
                        : failure.Message,
                    "Switzerland VPN Update",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }
            if (release == null)
            {
                FinishUpdateOperation(UpdateCheckState.Failed);
                MessageBox.Show(
                    "GitHub did not return release information. Nothing was downloaded.",
                    "Switzerland VPN Update",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            Version currentVersion = Version.Parse(AppConfig.CurrentVersion);
            int comparison = release.Version.CompareTo(currentVersion);
            if (comparison == 0)
            {
                FinishUpdateOperation(UpdateCheckState.Idle);
                MessageBox.Show(
                    "Switzerland VPN v" + AppConfig.CurrentVersion + " is already current.",
                    "No Update Needed",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }
            if (comparison < 0)
            {
                FinishUpdateOperation(UpdateCheckState.Idle);
                MessageBox.Show(
                    "This build is newer than the latest published release. No downgrade was performed.",
                    "No Update Needed",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            currentOperation = VpnOperation.AwaitingUpdateConfirmation;
            updateCheckState = UpdateCheckState.AwaitingConfirmation;
            ApplyBusyState(currentOperation);
            DialogResult answer = MessageBox.Show(
                "Switzerland VPN v" + release.VersionText + " is available. Download and install it now?\r\n\r\n" +
                "The app will close. Your VPN connection and kill switch will not be changed.",
                "Private Update Available",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button1);
            if (answer != DialogResult.Yes)
            {
                FinishUpdateOperation(UpdateCheckState.Idle);
                return;
            }

            BeginUpdaterPreparation(release);
        }

        private void BeginUpdaterPreparation(GitHubReleaseInfo release)
        {
            if (release == null) throw new ArgumentNullException("release");
            currentOperation = VpnOperation.PreparingUpdate;
            updateCheckState = UpdateCheckState.Preparing;
            ApplyBusyState(currentOperation);

            ThreadPool.QueueUserWorkItem(delegate
            {
                UpdaterHandoffResult result = PrepareUpdaterHandoff(release);
                PostToUi(delegate
                {
                    if (!result.Ready)
                    {
                        FinishUpdateOperation(UpdateCheckState.Failed);
                        MessageBox.Show(
                            result.FailureMessage,
                            "Switzerland VPN Update",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Error);
                        return;
                    }

                    currentOperation = VpnOperation.StartingUpdate;
                    updateCheckState = UpdateCheckState.Starting;
                    ApplyBusyState(currentOperation);
                    updaterHandoffStarted = true;
                    Close();
                });
            });
        }

        /// <summary>
        /// Starts the installed updater unelevated, then waits for its elevated child to validate the
        /// locked release and signal readiness. The form closes only after this handshake succeeds.
        /// </summary>
        private static UpdaterHandoffResult PrepareUpdaterHandoff(GitHubReleaseInfo release)
        {
            string installDirectory = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
            string updateScript = Path.Combine(installDirectory, AppConfig.UpdateScriptName);
            if (!File.Exists(updateScript))
            {
                return new UpdaterHandoffResult
                {
                    FailureMessage =
                        "The update helper is missing. Reinstall Switzerland VPN from the latest package, then try again."
                };
            }

            string transactionId = Guid.NewGuid().ToString("N");
            string localUpdateRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Justichuu",
                "Switzerland VPN",
                "Updates",
                transactionId);
            string protectedStatusRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Switzerland VPN",
                "Updates",
                transactionId);
            string readyPath = Path.Combine(protectedStatusRoot, "ready.txt");
            string protectedFailurePath = Path.Combine(protectedStatusRoot, "failure.txt");
            string localFailurePath = Path.Combine(localUpdateRoot, "failure.txt");
            string localCancelPath = Path.Combine(localUpdateRoot, "cancel.txt");

            try
            {
                ValidateInstalledUpdateHelper(installDirectory, updateScript);
                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
                string[] arguments =
                {
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-WindowStyle", "Hidden",
                    "-File", updateScript,
                    "-ExpectedTag", release.TagName,
                    "-ParentProcessId", Process.GetCurrentProcess().Id.ToString(
                        System.Globalization.CultureInfo.InvariantCulture),
                    "-ParentProcessStartTimeUtcTicks", Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString(
                        System.Globalization.CultureInfo.InvariantCulture),
                    "-GitHubCliPath", release.GitHubCliPath,
                    "-TransactionId", transactionId
                };
                ProcessStartInfo startInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = string.Join(
                        " ",
                        arguments.Select(PrivateUpdateManager.QuoteArgument).ToArray()),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = installDirectory
                };
                foreach (string variableName in new[] { "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_REPO", "GH_CONFIG_DIR" })
                    startInfo.EnvironmentVariables.Remove(variableName);

                using (Process updater = Process.Start(startInfo))
                {
                    if (updater == null)
                        throw new InvalidOperationException("Windows did not start the update helper.");

                    DateTime deadline = DateTime.UtcNow.AddMinutes(5);
                    while (DateTime.UtcNow < deadline)
                    {
                        if (File.Exists(readyPath)) return new UpdaterHandoffResult { Ready = true };
                        string failure = ReadHandshakeFailure(protectedFailurePath);
                        string localFailure = ReadHandshakeFailure(localFailurePath);
                        if (failure != null || localFailure != null)
                        {
                            if (localFailure != null) TryDeleteLocalUpdateDirectory(localUpdateRoot);
                            return new UpdaterHandoffResult { FailureMessage = failure ?? localFailure };
                        }
                        if (updater.HasExited)
                        {
                            Thread.Sleep(150);
                            failure = ReadHandshakeFailure(protectedFailurePath);
                            localFailure = ReadHandshakeFailure(localFailurePath);
                            if (localFailure != null) TryDeleteLocalUpdateDirectory(localUpdateRoot);
                            return new UpdaterHandoffResult
                            {
                                FailureMessage = failure ?? localFailure ??
                                    "The update helper stopped before it was ready. Nothing was installed."
                            };
                        }
                        Thread.Sleep(200);
                    }

                    try
                    {
                        Directory.CreateDirectory(localUpdateRoot);
                        File.WriteAllText(localCancelPath, "cancel", new UTF8Encoding(false));
                    }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                    try
                    {
                        if (updater.WaitForExit(5000)) TryDeleteLocalUpdateDirectory(localUpdateRoot);
                    }
                    catch (InvalidOperationException) { }
                    return new UpdaterHandoffResult
                    {
                        FailureMessage =
                            "The update did not become ready in five minutes. The app stayed open and nothing was installed."
                    };
                }
            }
            catch (Win32Exception ex)
            {
                return new UpdaterHandoffResult
                {
                    FailureMessage = ex.NativeErrorCode == 1223
                        ? "Administrator approval was canceled. The update was not installed."
                        : "Windows could not start the update helper. Nothing was installed."
                };
            }
            catch (Exception)
            {
                return new UpdaterHandoffResult
                {
                    FailureMessage = "Windows could not start the update helper. Nothing was installed."
                };
            }
        }

        private static string ReadHandshakeFailure(string failurePath)
        {
            if (!File.Exists(failurePath)) return null;
            try
            {
                string message = File.ReadAllText(failurePath).Trim();
                if (message.Length > 2000) message = message.Substring(0, 2000);
                return message.Length == 0
                    ? "The update helper stopped safely. Nothing was installed."
                    : message;
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        private static void TryDeleteLocalUpdateDirectory(string directory)
        {
            try
            {
                string safeRoot = Path.GetFullPath(Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Justichuu", "Switzerland VPN", "Updates")).TrimEnd('\\') + "\\";
                string resolved = Path.GetFullPath(directory).TrimEnd('\\');
                if (resolved.StartsWith(safeRoot, StringComparison.OrdinalIgnoreCase) &&
                    Regex.IsMatch(Path.GetFileName(resolved), "^[a-f0-9]{32}$", RegexOptions.CultureInvariant) &&
                    Directory.Exists(resolved))
                {
                    Directory.Delete(resolved, true);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// <summary>
        /// Binds update execution to the protected installation registered by the installer. This
        /// prevents a copied EXE from running an arbitrary same-name PowerShell file beside itself.
        /// </summary>
        private static void ValidateInstalledUpdateHelper(string installDirectory, string updateScript)
        {
            string normalizedInstall = Path.GetFullPath(installDirectory).TrimEnd('\\');
            string stateDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Switzerland VPN");
            string statePath = Path.Combine(stateDirectory, "install-state.json");
            string markerPath = Path.Combine(normalizedInstall, "install-ownership.json");
            if (!File.Exists(statePath) || !File.Exists(markerPath) || !File.Exists(updateScript))
            {
                throw new InvalidOperationException(
                    "Private updates require the installed copy of Switzerland VPN. Reinstall the latest package first.");
            }

            string state = File.ReadAllText(statePath);
            string marker = File.ReadAllText(markerPath);
            string stateProduct = ReadJsonStringProperty(state, "ProductName");
            string stateInstallId = ReadJsonStringProperty(state, "InstallId");
            string stateInstallDirectory = ReadJsonStringProperty(state, "InstallDirectory");
            string stateVersion = ReadJsonStringProperty(state, "Version");
            string markerProduct = ReadJsonStringProperty(marker, "ProductName");
            string markerInstallId = ReadJsonStringProperty(marker, "InstallId");
            string markerInstallDirectory = ReadJsonStringProperty(marker, "InstallDirectory");
            string markerVersion = ReadJsonStringProperty(marker, "Version");
            Guid parsedInstallId;
            if (!string.Equals(stateProduct, AppConfig.VpnName, StringComparison.Ordinal) ||
                !string.Equals(markerProduct, AppConfig.VpnName, StringComparison.Ordinal) ||
                !Guid.TryParse(stateInstallId, out parsedInstallId) ||
                !string.Equals(stateInstallId, markerInstallId, StringComparison.Ordinal) ||
                !string.Equals(stateVersion, AppConfig.CurrentVersion, StringComparison.Ordinal) ||
                !string.Equals(stateVersion, markerVersion, StringComparison.Ordinal) ||
                !string.Equals(
                    Path.GetFullPath(stateInstallDirectory).TrimEnd('\\'),
                    normalizedInstall,
                    StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(
                    Path.GetFullPath(markerInstallDirectory).TrimEnd('\\'),
                    normalizedInstall,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "The installation ownership records do not match this app. Nothing was downloaded.");
            }

            using (Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Switzerland VPN Widget",
                false))
            {
                if (key == null ||
                    !AppConfig.IsSupportedPublisher(Convert.ToString(key.GetValue("Publisher"))) ||
                    !string.Equals(Convert.ToString(key.GetValue("DisplayVersion")), AppConfig.CurrentVersion, StringComparison.Ordinal) ||
                    !string.Equals(
                        Path.GetFullPath(Convert.ToString(key.GetValue("InstallLocation"))).TrimEnd('\\'),
                        normalizedInstall,
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "Windows does not recognize this as the installed Switzerland VPN app. Nothing was downloaded.");
                }
            }

            if ((File.GetAttributes(updateScript) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("The installed update helper is linked. Update stopped safely.");
        }

        private static string ReadJsonStringProperty(string json, string propertyName)
        {
            if (json == null) throw new ArgumentNullException("json");
            Match match = Regex.Match(
                json,
                "\\\"" + Regex.Escape(propertyName) + "\\\"\\s*:\\s*\\\"(?<value>(?:\\\\.|[^\\\"])*)\\\"",
                RegexOptions.CultureInvariant);
            if (!match.Success)
                throw new InvalidOperationException("The installation ownership data is incomplete.");
            return Regex.Unescape(match.Groups["value"].Value);
        }

        private void PostToUi(Action action)
        {
            if (action == null || IsDisposed || Disposing) return;
            try { BeginInvoke(action); }
            catch (InvalidOperationException) { }
        }

        private void FinishUpdateOperation(UpdateCheckState finalState)
        {
            updateCheckState = finalState;
            currentOperation = VpnOperation.None;
            ResetActionLabels();
            UseWaitCursor = false;
            UpdateStatus();
            ResumeMonitoringAfterAction();
            if (finalState == UpdateCheckState.Failed) updateCheckState = UpdateCheckState.Idle;
        }

        private void HandleDisabledControlToolTip(object sender, MouseEventArgs e)
        {
            Control hovered = GetChildAtPoint(e.Location, GetChildAtPointSkip.Invisible);
            string text;
            if (hovered == null || hovered.Enabled || !controlToolTipText.TryGetValue(hovered, out text))
            {
                if (lastDisabledToolTipControl != null) toolTips.Hide(this);
                lastDisabledToolTipControl = null;
                return;
            }

            if (ReferenceEquals(lastDisabledToolTipControl, hovered)) return;
            lastDisabledToolTipControl = hovered;
            toolTips.Show(text, this, e.X + 12, e.Y + 18, 4500);
        }

        private static Button NewButton(string text, Point location, Color color, Size size)
        {
            Button button = new Button
            {
                Text = text,
                Location = location,
                Size = size,
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
                BackColor = color,
                ForeColor = Color.White,
                Font = new Font("Segoe UI Semibold", 9f),
                Cursor = Cursors.Hand
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(225, 229, 237);
            return button;
        }

        private static Button NewSmallButton(string text, Point location, Size size, Color color)
        {
            Button button = NewButton(text, location, color, size);
            button.Font = new Font("Segoe UI Semibold", 7.25f);
            return button;
        }

        /// <summary>
        /// Renders the external theme and dark readability overlay once. Reusing this client-sized
        /// bitmap prevents telemetry label repaints from rescaling the large source image.
        /// </summary>
        private static Image LoadThemeBackground(Size clientSize)
        {
            string path = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "Switzerland VPN Background.png");
            if (!File.Exists(path)) return null;

            try
            {
                using (Image source = Image.FromFile(path))
                {
                    Bitmap rendered = new Bitmap(
                        clientSize.Width,
                        clientSize.Height,
                        System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                    using (Graphics graphics = Graphics.FromImage(rendered))
                    {
                        graphics.Clear(Color.FromArgb(24, 26, 31));
                        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        graphics.DrawImage(source, new Rectangle(Point.Empty, clientSize));
                        using (SolidBrush overlay = new SolidBrush(Color.FromArgb(105, 8, 10, 17)))
                            graphics.FillRectangle(overlay, new Rectangle(Point.Empty, clientSize));
                    }
                    return rendered;
                }
            }
            catch
            {
                // A missing or damaged optional theme must never prevent recovery controls from opening.
                return null;
            }
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (themeBackground == null)
            {
                base.OnPaintBackground(e);
                return;
            }

            e.Graphics.Clear(BackColor);
            if (themeBackground.Size == ClientSize)
                e.Graphics.DrawImageUnscaled(themeBackground, Point.Empty);
            else
                e.Graphics.DrawImage(themeBackground, ClientRectangle);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                monitoringStopped = true;
                monitoringPausedForAction = true;
                CancelLeakProbe();
                if (timer != null)
                {
                    timer.Stop();
                    timer.Dispose();
                }
                if (toolTips != null) toolTips.Dispose();
                if (trayIcon != null) trayIcon.Dispose();
                if (themeBackground != null) themeBackground.Dispose();
            }
            base.Dispose(disposing);
        }

        private void BeginConnect()
        {
            if (IsActionRunning || previewState != null) return;

            try
            {
                if (!RasManager.IsConnected(AppConfig.VpnName) &&
                    !RasManager.HasSavedCredentials(AppConfig.VpnName))
                {
                    bool killSwitchAlreadyActive = false;
                    try
                    {
                        FirewallRuleState existingRules = FirewallManager.GetRuleState();
                        killSwitchAlreadyActive = existingRules.Found > 0;
                    }
                    catch { }

                    string networkNotice = killSwitchAlreadyActive
                        ? "The kill switch was already active and remains active. Choose DISCONNECT + UNLOCK to restore normal internet."
                        : "This attempt did not change the VPN or kill switch.";
                    DialogResult answer = MessageBox.Show(
                        "Sign-in has not been set up for Switzerland VPN.\r\n\r\n" +
                        "Choose Yes to arm the kill switch and open SET UP SIGN-IN. Enter the NordVPN manual " +
                        "service username and password, then connect in the Windows dialog. " +
                        "Ask Justichuu if you need the credentials.\r\n\r\n" +
                        networkNotice,
                        "Sign-In Required",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Information,
                        MessageBoxDefaultButton.Button2);
                    if (answer == DialogResult.Yes) BeginProtectedSignIn(true);
                    return;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.Connect,
                SuccessMessage = "Switzerland is connected and protected.",
                Execute = delegate
                {
                    ArmKillSwitchAndVerify();

                    // Do not disturb another live connection until the kill switch has been
                    // independently observed by the unelevated UI process.
                    RasManager.DisconnectOtherConnections(AppConfig.VpnName);
                    RasManager.Connect(AppConfig.VpnName, true);

                    if (!RasManager.IsConnected(AppConfig.VpnName))
                        throw new InvalidOperationException(
                            "The VPN dropped after arming. Internet remains blocked until you unlock it.");

                    VerifyPostConnectProtectionOrDisconnect();
                }
            });
        }

        private void BeginConnectOnly()
        {
            if (IsActionRunning || previewState != null) return;

            WidgetState state;
            try
            {
                state = ReadState();
                if (state.Connected) return;
                if (!RasManager.HasSavedCredentials(AppConfig.VpnName))
                {
                    MessageBox.Show(
                        "Sign-in has not been set up for Switzerland VPN. Choose SET UP SIGN-IN, save the NordVPN manual service credentials, then try CONNECT ONLY again.",
                        "Sign-In Required",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }
                if (state.KillSwitchIncomplete && !state.FirewallProtectionOff)
                {
                    MessageBox.Show(
                        "Kill-switch setup is incomplete. Choose UNLOCK ONLY or DISCONNECT + UNLOCK before connecting.",
                        "Protection Incomplete",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            bool alreadyProtected = state.KillSwitchActive && !state.FirewallProtectionOff;
            if (!alreadyProtected)
            {
                string warning = state.FirewallProtectionOff
                    ? "Windows Firewall protection is off. CONNECT ONLY will start Switzerland without verified kill-switch protection. If the VPN drops, traffic may use normal internet. Continue?"
                    : "CONNECT ONLY will start Switzerland without arming the kill switch. It will not close other VPN connections. If Switzerland drops, traffic may use normal internet. Continue?";
                if (!ConfirmPartialAction("Connect Without Arming?", warning)) return;
            }

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.ConnectOnly,
                SuccessMessage = "Switzerland connected. Kill-switch state was not changed.",
                Execute = delegate
                {
                    RasManager.Connect(AppConfig.VpnName, false);
                    if (!RasManager.IsConnected(AppConfig.VpnName))
                        throw new InvalidOperationException("Switzerland VPN did not report a connected state.");
                }
            });
        }

        private static bool ReadAllowAnyNordVpnSetting()
        {
            try { return AppConfig.AllowAnyNordVpnServer; }
            catch { return false; }
        }

        private static void SaveAllowAnyNordVpnSetting(bool value)
        {
            try { AppConfig.AllowAnyNordVpnServer = value; }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        /// <summary>
        /// Validates the selected hostname before launching the transactional elevated switcher.
        /// The switcher performs the authoritative connected/firewall checks and updates the RAS
        /// profile, persisted server file, and install state as one rollback-capable operation.
        /// </summary>
        private void BeginServerChange()
        {
            if (IsActionRunning || previewState != null) return;

            string hostname;
            try
            {
                hostname = NetworkSafety.NormalizeServerHostname(
                    serverComboBox.Text,
                    allowAnyNordVpnCheck.Checked);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Invalid VPN Server", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (string.Equals(hostname, AppConfig.ServerHost, StringComparison.OrdinalIgnoreCase)) return;
            bool allowAny = allowAnyNordVpnCheck.Checked;
            if (MessageBox.Show(
                "Change the Windows VPN profile and kill-switch server to:\r\n\r\n" + hostname +
                "\r\n\r\nThe VPN must be disconnected and the kill switch unlocked.",
                "Apply VPN Server?",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.ChangeServer,
                SuccessMessage = "VPN server changed to " + hostname + ".",
                Execute = delegate { RunServerSwitcher(hostname, allowAny); }
            });
        }

        private static void RunServerSwitcher(string hostname, bool allowAnyNordVpnServer)
        {
            string scriptPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                AppConfig.ServerSwitcherScriptName);
            if (!File.Exists(scriptPath))
                throw new InvalidOperationException(
                    "The server-switch helper is missing. Reinstall Switzerland VPN before changing servers.");

            string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath +
                "\" -Server \"" + hostname + "\"" +
                (allowAnyNordVpnServer ? " -AllowAnyNordVpn" : string.Empty);
            Process process;
            try
            {
                process = Process.Start(new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = arguments,
                    UseShellExecute = true,
                    Verb = "runas",
                    WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
                    WindowStyle = ProcessWindowStyle.Hidden
                });
                if (process == null)
                    throw new InvalidOperationException("Windows could not open Administrator approval.");
            }
            catch (Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223)
                    throw new InvalidOperationException("Administrator approval was canceled. The VPN server was not changed.");
                throw new InvalidOperationException("Windows could not open Administrator approval for the server change.", ex);
            }

            using (process)
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException(
                        "The VPN server change failed. The previous setting should still be active; run the switch helper manually for detailed output.");
            }
        }

        private void BeginArmOnly()
        {
            if (IsActionRunning || previewState != null) return;

            WidgetState state;
            try
            {
                state = ReadState();
                if (state.FirewallProtectionOff)
                    throw new FirewallProtectionException(
                        "Windows Defender Firewall is off. Turn it on before using ARM ONLY.");
                if (state.KillSwitchIncomplete)
                    throw new InvalidOperationException(
                        "Kill-switch setup is incomplete. Choose UNLOCK ONLY or DISCONNECT + UNLOCK before arming again.");
                if (state.KillSwitchActive) return;
                AssertNoOtherRasConnectionsForArmOnly();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (!state.Connected && !ConfirmPartialAction(
                "Arm Without Connecting?",
                "ARM ONLY will block normal internet and DNS without connecting the VPN. The block persists until a VPN connection succeeds or you choose UNLOCK ONLY or DISCONNECT + UNLOCK. Continue?"))
                return;

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.ArmOnly,
                SuccessMessage = state.Connected
                    ? "Kill switch armed. Switzerland remains connected."
                    : "Kill switch armed. Normal internet is blocked.",
                Execute = ArmKillSwitchAndVerify
            });
        }

        private void BeginDisconnectOnly()
        {
            if (IsActionRunning || previewState != null) return;

            WidgetState state;
            try
            {
                state = ReadState();
                if (!state.Connected) return;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string warning = state.KillSwitchActive && !state.FirewallProtectionOff
                ? "DISCONNECT ONLY will stop Switzerland but leave the kill switch armed. Normal internet will remain blocked. Use CONNECT ONLY to attempt reconnection or UNLOCK ONLY to restore normal internet. Continue?"
                : "DISCONNECT ONLY will stop Switzerland without changing firewall rules. The kill switch is not fully active, so traffic may use normal internet immediately. Continue?";
            if (!ConfirmPartialAction("Disconnect Without Unlocking?", warning)) return;

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.DisconnectOnly,
                SuccessMessage = "Switzerland disconnected. Kill-switch state was not changed.",
                Execute = delegate { RasManager.Disconnect(AppConfig.VpnName); }
            });
        }

        private void BeginUnlockOnly()
        {
            if (IsActionRunning || previewState != null) return;

            WidgetState state;
            try
            {
                state = ReadState();
                if (!state.ManagedRulesPresent && !state.KillSwitchActive && !state.KillSwitchIncomplete) return;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string warning = state.Connected
                ? "UNLOCK ONLY will remove kill-switch firewall rules and leave Switzerland connected. If the VPN drops, traffic may use normal internet. Continue?"
                : "UNLOCK ONLY will remove the kill-switch firewall rules and restore normal internet. Switzerland will remain disconnected. Continue?";
            if (!ConfirmPartialAction("Unlock Without Disconnecting?", warning)) return;

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.UnlockOnly,
                SuccessMessage = "Kill switch removed. VPN connection state was not changed.",
                Execute = delegate { RunElevatedHelper("--firewall-remove", null); }
            });
        }

        private static void AssertNoOtherRasConnectionsForArmOnly()
        {
            string[] otherConnections = RasManager.GetConnections()
                .Where(c => !string.Equals(c.Name, AppConfig.VpnName, StringComparison.OrdinalIgnoreCase))
                .Select(c => string.IsNullOrWhiteSpace(c.Name) ? "(unnamed RAS connection)" : c.Name)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            if (otherConnections.Length == 0) return;

            throw new InvalidOperationException(
                "ARM ONLY does not disconnect other VPN connections. Disconnect these connections first, or use CONNECT + ARM:\r\n\r\n" +
                string.Join("\r\n", otherConnections));
        }

        private static bool ConfirmPartialAction(string title, string message)
        {
            return MessageBox.Show(
                message,
                title,
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2) == DialogResult.Yes;
        }

        private void BeginDisconnect()
        {
            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.Disconnect,
                SuccessMessage = "Switzerland is disconnected. Normal internet is restored.",
                Execute = delegate
                {
                    // Restore normal networking first, even if the tunnel is already down.
                    // RAS sessions displaced during takeover are deliberately not restarted.
                    RunElevatedHelper("--firewall-remove", null);
                    RasManager.Disconnect(AppConfig.VpnName);
                }
            });
        }

        /// <summary>
        /// Arms and verifies fail-closed firewall protection before opening Windows' RAS dial
        /// dialog. The dialog can establish a connection, so it must never be opened unprotected.
        /// </summary>
        private void BeginProtectedSignIn(bool warningAlreadyAccepted)
        {
            if (IsActionRunning || previewState != null) return;

            if (!warningAlreadyAccepted)
            {
                DialogResult answer = MessageBox.Show(
                    "Windows may connect the VPN from its sign-in dialog. Switzerland VPN will arm the whole-computer " +
                    "kill switch first. If you cancel sign-in, normal internet stays blocked until you choose " +
                    "DISCONNECT + UNLOCK.\r\n\r\nContinue?",
                    "Set Up Sign-In Safely?",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2);
                if (answer != DialogResult.Yes) return;
            }

            RunAction(new VpnActionRequest
            {
                Operation = VpnOperation.PrepareSignIn,
                SuccessMessage = "Protected sign-in is open. Unlock if you cancel it.",
                Execute = delegate
                {
                    ArmKillSwitchAndVerify();
                    RasManager.DisconnectOtherConnections(AppConfig.VpnName);
                    RasManager.OpenSignIn(AppConfig.VpnName);
                }
            });
        }

        /// <summary>
        /// Creates all managed rules and verifies their exact semantics from the unelevated process.
        /// </summary>
        private static void ArmKillSwitchAndVerify()
        {
            IPAddress[] servers = NetworkSafety.ResolveAndValidateServer(AppConfig.ServerHost);
            NetworkSafety.AssertSupportedEgress();
            FirewallManager.AssertFirewallAvailable();
            RunElevatedHelper(
                "--firewall-arm",
                string.Join(",", servers.Select(a => a.ToString()).ToArray()));

            FirewallRuleState armed = FirewallManager.GetRuleState();
            if (armed.Valid != AppConfig.RuleNames.Length)
                throw new InvalidOperationException(
                    "The kill switch did not remain fully armed. Existing VPN connections were not changed. " +
                    "Use DISCONNECT + UNLOCK before trying again.");
        }

        /// <summary>
        /// Rechecks protection after dialing. If protection cannot be proven, the new VPN session is
        /// disconnected so the application never reports an unprotected connection as successful.
        /// </summary>
        private static void VerifyPostConnectProtectionOrDisconnect()
        {
            Exception protectionFailure = null;
            try
            {
                FirewallRuleState state = FirewallManager.GetRuleState();
                if (state.Valid == AppConfig.RuleNames.Length) return;
                protectionFailure = new InvalidOperationException(
                    "The managed firewall rules no longer match the required protection.");
            }
            catch (Exception ex)
            {
                protectionFailure = ex;
            }

            try
            {
                RasManager.Disconnect(AppConfig.VpnName);
            }
            catch (Exception disconnectFailure)
            {
                throw new InvalidOperationException(
                    "Protection could not be verified, and Windows could not disconnect the VPN. " +
                    "Use DISCONNECT + UNLOCK immediately. Internet may be unprotected or blocked.",
                    new AggregateException(protectionFailure, disconnectFailure));
            }

            throw new InvalidOperationException(
                "Protection could not be verified after connecting, so Switzerland VPN was disconnected. " +
                "Firewall rules remain fail-closed; use DISCONNECT + UNLOCK to restore normal internet.",
                protectionFailure);
        }

        private static void RunElevatedHelper(string command, string value)
        {
            string arguments = command;
            if (!string.IsNullOrEmpty(value)) arguments += " " + QuoteCommandLine(value);

            Process process;
            try
            {
                process = Process.Start(new ProcessStartInfo
                {
                    FileName = Application.ExecutablePath,
                    Arguments = arguments,
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden
                });
                if (process == null)
                    throw new InvalidOperationException(
                        "Windows could not open Administrator approval. Try again or ask Justichuu.");
            }
            catch (Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223)
                    throw new InvalidOperationException("Administrator approval was canceled. No changes were made.");
                throw new InvalidOperationException(
                    "Windows could not open Administrator approval. Try again or ask Justichuu.");
            }

            using (process)
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    if (string.Equals(command, "--firewall-arm", StringComparison.OrdinalIgnoreCase))
                    {
                        string armFailure =
                            "The kill switch could not be turned on. No VPN connection was changed.";
                        try
                        {
                            FirewallRuleState stored = FirewallManager.GetStoredRuleState();
                            armFailure = stored.Found > 0
                                ? "Kill-switch setup failed and some firewall rules remain. Internet may be blocked. " +
                                  "Use DISCONNECT + UNLOCK or Emergency Unlock."
                                : armFailure + " No partial firewall rules remain.";
                        }
                        catch
                        {
                            armFailure =
                                "Kill-switch setup failed, and Windows could not verify whether partial firewall rules remain. " +
                                "Internet may be blocked. Use DISCONNECT + UNLOCK or Emergency Unlock.";
                        }
                        throw new InvalidOperationException(armFailure);
                    }
                    if (string.Equals(command, "--firewall-remove", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException(
                            "The kill switch could not be fully removed. Internet may still be blocked. " +
                            "Run Emergency Unlock or ask Justichuu.");
                    if (string.Equals(command, "--clear-default-credentials", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException(
                            "Windows could not clear the shared default VPN sign-in. " +
                            "The sign-in saved for this Windows account was not changed. Try again or ask Justichuu.");
                    throw new InvalidOperationException("The requested VPN change failed. Try again or ask Justichuu.");
                }
            }
        }

        private static string QuoteCommandLine(string value)
        {
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        private void ClearSavedCredentials()
        {
            if (IsActionRunning || previewState != null) return;

            bool connected = false;
            try { connected = RasManager.IsConnected(AppConfig.VpnName); }
            catch { }

            string confirmation =
                "Clear the username, password, and domain saved by Windows for Switzerland VPN?\r\n\r\n" +
                (connected
                    ? "The current VPN connection will stay open, but SET UP SIGN-IN will be required after it disconnects."
                    : "SET UP SIGN-IN will be required before the next connection.");

            DialogResult answer = MessageBox.Show(
                confirmation,
                "Clear Saved Credentials?",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) return;

            currentOperation = VpnOperation.ClearCredentials;
            timer.Stop();
            UseWaitCursor = true;
            ApplyControlState(null);

            bool sharedDefaultCleared = false;
            try
            {
                // Clear shared defaults while elevated, then return to the original Windows
                // identity to clear that user's private RAS credential record.
                RunElevatedHelper("--clear-default-credentials", null);
                sharedDefaultCleared = true;
                RasManager.ClearCurrentUserCredentials(AppConfig.VpnName);
                if (RasManager.HasSavedCredentials(AppConfig.VpnName))
                    throw new InvalidOperationException(
                        "Windows still reports a saved Switzerland VPN sign-in for this account. " +
                        "Nothing was reported as cleared; try again or ask Justichuu.");
                MessageBox.Show(
                    "The shared default sign-in and credentials saved for this Windows account are now cleared.\r\n\r\n" +
                    (connected
                        ? "The current VPN connection was not disconnected. Use SET UP SIGN-IN before reconnecting."
                        : "Use SET UP SIGN-IN before connecting."),
                    "Credentials Cleared",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                string message = sharedDefaultCleared
                    ? "The shared default sign-in was cleared, but the sign-in saved for this Windows account was not.\r\n\r\n" +
                      ex.Message
                    : ex.Message;
                MessageBox.Show(message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                currentOperation = VpnOperation.None;
                UseWaitCursor = false;
                UpdateStatus();
                ResumeMonitoringAfterAction();
            }
        }

        /// <summary>
        /// Runs one serialized VPN transition off the UI thread and returns all completion handling
        /// to the form thread. The operation enum is the single source of truth for the busy state.
        /// </summary>
        private void RunAction(VpnActionRequest request)
        {
            if (request == null) throw new ArgumentNullException("request");
            if (request.Execute == null) throw new ArgumentException("The VPN action has no work to run.", "request");
            if (request.Operation == VpnOperation.None)
                throw new ArgumentException("The VPN action must declare an operation.", "request");
            if (IsActionRunning || previewState != null) return;

            currentOperation = request.Operation;
            PauseMonitoringForAction();
            ApplyBusyState(request.Operation);
            UseWaitCursor = true;

            ThreadPool.QueueUserWorkItem(delegate
            {
                Exception failure = null;
                try { request.Execute(); }
                catch (Exception ex) { failure = ex; }

                BeginInvoke(new Action(delegate
                {
                    currentOperation = VpnOperation.None;
                    ResetActionLabels();
                    UseWaitCursor = false;
                    if (failure == null && request.Operation == VpnOperation.ChangeServer)
                        serverComboBox.Text = AppConfig.ServerHost;
                    UpdateStatus();
                    ResumeMonitoringAfterAction();

                    if (failure != null)
                    {
                        MessageBox.Show(failure.Message, "Switzerland VPN", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    else
                    {
                        trayIcon.BalloonTipTitle = "Switzerland VPN";
                        trayIcon.BalloonTipText = request.SuccessMessage;
                        trayIcon.BalloonTipIcon = ToolTipIcon.Info;
                        trayIcon.ShowBalloonTip(2500);
                    }
                }));
            });
        }

        private void PauseMonitoringForAction()
        {
            Interlocked.Increment(ref monitoringEpoch);
            monitoringPausedForAction = true;
            timer.Stop();
            lock (monitoringSync)
            {
                protectionGeneration++;
                monitoredConnectionVerified = false;
                monitoredConnectionObservedUtc = DateTime.MinValue;
                monitoredTrafficReady = false;
                previousTrafficSample = null;
                monitoredPingAvailable = false;
                monitoredPingSucceeded = false;
                leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
                nextLeakProbeAllowedUtc = DateTime.MinValue;
            }
            CancelLeakProbe();
            if (monitoringEnabled)
            {
                SetTelemetryDisplay(
                    "ACTION RUNNING | LIVE CHECK PAUSED",
                    Color.FromArgb(84, 150, 235));
                SetLeakDisplay(
                    "ROUTE CHECK PAUSED DURING ACTION",
                    Color.FromArgb(84, 150, 235),
                    "IP LEAK CHECK: PAUSED",
                    Color.FromArgb(84, 150, 235));
            }
        }

        private void ApplyBusyState(VpnOperation operation)
        {
            bool connecting = operation == VpnOperation.Connect;
            bool connectingOnly = operation == VpnOperation.ConnectOnly;
            bool armingOnly = operation == VpnOperation.ArmOnly;
            bool disconnecting = operation == VpnOperation.Disconnect;
            bool disconnectingOnly = operation == VpnOperation.DisconnectOnly;
            bool unlockingOnly = operation == VpnOperation.UnlockOnly;
            bool preparingSignIn = operation == VpnOperation.PrepareSignIn;
            bool changingServer = operation == VpnOperation.ChangeServer;
            connectButton.Text = connecting ? "CONNECTING..." : "CONNECT + ARM";
            connectOnlyButton.Text = connectingOnly ? "CONNECT..." : "CONNECT";
            armOnlyButton.Text = armingOnly ? "ARM..." : "ARM";
            disconnectButton.Text = disconnecting ? "DISCONNECTING..." : "DISCONNECT + UNLOCK";
            disconnectOnlyButton.Text = disconnectingOnly ? "STOP..." : "DISCONNECT";
            unlockOnlyButton.Text = unlockingOnly ? "UNLOCK..." : "UNLOCK";
            signInButton.Text = preparingSignIn ? "ARMING SIGN-IN..." : "SET UP SIGN-IN";
            applyServerButton.Text = changingServer ? "APPLYING..." : "APPLY";
            trayConnectItem.Text = connecting ? "Connecting + Arming..." : "Connect + Arm";
            trayConnectOnlyItem.Text = connectingOnly ? "Connecting Only..." : "Connect Only...";
            trayArmOnlyItem.Text = armingOnly ? "Arming Only..." : "Arm Only...";
            trayDisconnectItem.Text = disconnecting ? "Disconnecting + Unlocking..." : "Disconnect + Unlock";
            trayDisconnectOnlyItem.Text = disconnectingOnly ? "Disconnecting Only..." : "Disconnect Only...";
            trayUnlockOnlyItem.Text = unlockingOnly ? "Unlocking Only..." : "Unlock Only...";
            traySignInItem.Text = preparingSignIn ? "Arming Protected Sign-In..." : "Set Up Sign-In";
            switch (updateCheckState)
            {
                case UpdateCheckState.Checking:
                    updateLink.Text = "CHECKING...";
                    trayUpdateItem.Text = "Checking for Updates...";
                    break;
                case UpdateCheckState.AwaitingConfirmation:
                    updateLink.Text = "UPDATE READY";
                    trayUpdateItem.Text = "Update Available";
                    break;
                case UpdateCheckState.Preparing:
                    updateLink.Text = "PREPARING...";
                    trayUpdateItem.Text = "Preparing Update...";
                    break;
                case UpdateCheckState.Starting:
                    updateLink.Text = "STARTING...";
                    trayUpdateItem.Text = "Starting Update...";
                    break;
                default:
                    updateLink.Text = "CHECK UPDATE";
                    trayUpdateItem.Text = "Check for Updates...";
                    break;
            }
            ApplyControlState(null);

            if (operation == VpnOperation.CheckingUpdate)
            {
                ApplyStatus(Color.FromArgb(84, 150, 235), "CHECKING FOR UPDATE",
                    "Reading the private GitHub release...", "Checking for update");
                return;
            }
            if (operation == VpnOperation.AwaitingUpdateConfirmation)
            {
                ApplyStatus(Color.FromArgb(84, 150, 235), "UPDATE AVAILABLE",
                    "Waiting for your answer...", "Update available");
                return;
            }
            if (operation == VpnOperation.PreparingUpdate)
            {
                ApplyStatus(Color.FromArgb(84, 150, 235), "PREPARING UPDATE",
                    "Downloading and verifying the private release...", "Preparing update");
                return;
            }
            if (operation == VpnOperation.StartingUpdate)
            {
                ApplyStatus(Color.FromArgb(84, 150, 235), "STARTING UPDATE",
                    "The VPN and kill switch will stay as they are.", "Starting update");
                return;
            }
            if (operation == VpnOperation.ChangeServer)
            {
                ApplyStatus(Color.FromArgb(84, 150, 235), "CHANGING SERVER",
                    "Validating and updating the Windows VPN profile...", "Changing VPN server");
                return;
            }

            if (operation == VpnOperation.Connect)
            {
                ApplyDisplayState(WidgetDisplayState.Connecting, null);
            }
            else if (operation == VpnOperation.ConnectOnly)
            {
                ApplyDisplayState(WidgetDisplayState.ConnectingOnly, null);
            }
            else if (operation == VpnOperation.ArmOnly)
            {
                ApplyDisplayState(WidgetDisplayState.ArmingOnly, null);
            }
            else if (operation == VpnOperation.PrepareSignIn)
            {
                ApplyDisplayState(WidgetDisplayState.PreparingSignIn, null);
            }
            else if (operation == VpnOperation.Disconnect)
            {
                ApplyDisplayState(WidgetDisplayState.Disconnecting, null);
            }
            else if (operation == VpnOperation.DisconnectOnly)
            {
                ApplyDisplayState(WidgetDisplayState.DisconnectingOnly, null);
            }
            else if (operation == VpnOperation.UnlockOnly)
            {
                ApplyDisplayState(WidgetDisplayState.UnlockingOnly, null);
            }
        }

        private void ResetActionLabels()
        {
            connectButton.Text = "CONNECT + ARM";
            connectOnlyButton.Text = "CONNECT";
            armOnlyButton.Text = "ARM";
            disconnectButton.Text = "DISCONNECT + UNLOCK";
            disconnectOnlyButton.Text = "DISCONNECT";
            unlockOnlyButton.Text = "UNLOCK";
            signInButton.Text = "SET UP SIGN-IN";
            applyServerButton.Text = "APPLY";
            trayConnectItem.Text = "Connect + Arm";
            trayConnectOnlyItem.Text = "Connect Only...";
            trayArmOnlyItem.Text = "Arm Only...";
            trayDisconnectItem.Text = "Disconnect + Unlock";
            trayDisconnectOnlyItem.Text = "Disconnect Only...";
            trayUnlockOnlyItem.Text = "Unlock Only...";
            traySignInItem.Text = "Set Up Sign-In";
            updateLink.Text = "CHECK UPDATE";
            trayUpdateItem.Text = "Check for Updates...";
        }

        private void ApplyControlState(WidgetState state)
        {
            bool protectedState = state != null && state.Connected && state.KillSwitchActive && !state.KillSwitchIncomplete;
            bool fullyInactive = state != null && !state.Connected && !state.KillSwitchActive && !state.KillSwitchIncomplete;
            bool protectionCanArm = state != null && !state.FirewallProtectionOff;
            bool connectEnabled = !IsActionRunning && protectionCanArm && !protectedState && !state.KillSwitchIncomplete;
            bool disconnectEnabled = !IsActionRunning && (state == null || !fullyInactive);
            bool connectOnlyEnabled = !IsActionRunning && state != null && !state.Connected &&
                (!state.KillSwitchIncomplete || state.FirewallProtectionOff);
            bool armOnlyEnabled = !IsActionRunning && protectionCanArm &&
                !state.KillSwitchActive && !state.KillSwitchIncomplete;
            bool disconnectOnlyEnabled = !IsActionRunning && state != null && state.Connected;
            bool unlockOnlyEnabled = !IsActionRunning &&
                (state == null || state.ManagedRulesPresent || state.KillSwitchActive || state.KillSwitchIncomplete);
            bool signInEnabled = !IsActionRunning && protectionCanArm;

            SetButtonAvailability(connectButton, connectEnabled, ConnectButtonColor);
            SetButtonAvailability(connectOnlyButton, connectOnlyEnabled, ConnectButtonColor);
            SetButtonAvailability(armOnlyButton, armOnlyEnabled, ConnectButtonColor);
            SetButtonAvailability(disconnectButton, disconnectEnabled, DisconnectButtonColor);
            SetButtonAvailability(disconnectOnlyButton, disconnectOnlyEnabled, DisconnectButtonColor);
            SetButtonAvailability(unlockOnlyButton, unlockOnlyEnabled, DisconnectButtonColor);
            signInButton.Enabled = signInEnabled;
            clearCredentialsButton.Enabled = !IsActionRunning;
            refreshButton.Enabled = !IsActionRunning;
            serverComboBox.Enabled = !IsActionRunning && previewState == null;
            allowAnyNordVpnCheck.Enabled = !IsActionRunning && previewState == null;
            SetButtonAvailability(
                applyServerButton,
                !IsActionRunning && previewState == null,
                Color.FromArgb(55, 89, 144));
            monitorCheck.Enabled = !IsActionRunning;
            trayConnectItem.Enabled = connectEnabled;
            trayConnectOnlyItem.Enabled = connectOnlyEnabled;
            trayArmOnlyItem.Enabled = armOnlyEnabled;
            trayDisconnectItem.Enabled = disconnectEnabled;
            trayDisconnectOnlyItem.Enabled = disconnectOnlyEnabled;
            trayUnlockOnlyItem.Enabled = unlockOnlyEnabled;
            traySignInItem.Enabled = signInEnabled;
            trayClearCredentialsItem.Enabled = !IsActionRunning;
            updateLink.Enabled = !IsActionRunning && previewState == null;
            trayUpdateItem.Enabled = !IsActionRunning && previewState == null;
        }

        private static void SetButtonAvailability(Button button, bool enabled, Color enabledColor)
        {
            button.Enabled = enabled;
            button.BackColor = enabled ? enabledColor : DisabledButtonColor;
            button.ForeColor = enabled ? Color.White : Color.FromArgb(164, 169, 179);
            button.FlatAppearance.BorderColor = enabled
                ? Color.FromArgb(235, 238, 244)
                : Color.FromArgb(92, 97, 108);
            button.Cursor = enabled ? Cursors.Hand : Cursors.Default;
        }

        private WidgetState ReadState()
        {
            if (previewState != null) return previewState;
            List<RasConnection> connections = RasManager.GetConnections();
            RasConnection[] matches = connections
                .Where(c => string.Equals(c.Name, AppConfig.VpnName, StringComparison.OrdinalIgnoreCase))
                .ToArray();
            bool connected = matches.Any(c => RasManager.IsConnectionEstablished(c.Handle));
            bool ambiguous = matches.Length > 1 || connections.Any(c =>
                !string.Equals(c.Name, AppConfig.VpnName, StringComparison.OrdinalIgnoreCase));
            IntPtr connectionHandle = matches.Length == 1 ? matches[0].Handle : IntPtr.Zero;
            uint tunnelInterfaceIndex = matches.Length == 1 && connected
                ? RasManager.GetConnectionInterfaceIndex(matches[0].Handle)
                : 0;

            try
            {
                FirewallRuleState firewall = FirewallManager.GetRuleState();
                WidgetState state = new WidgetState
                {
                    Connected = connected,
                    ConnectionAmbiguous = ambiguous,
                    ConnectionHandle = connectionHandle,
                    TunnelInterfaceIndex = tunnelInterfaceIndex,
                    ManagedRulesPresent = firewall.Found > 0,
                    KillSwitchActive = firewall.Valid == AppConfig.RuleNames.Length,
                    KillSwitchIncomplete = firewall.Found > 0 &&
                        firewall.Valid != AppConfig.RuleNames.Length
                };
                if (state.Connected && !state.ConnectionAmbiguous && state.KillSwitchActive)
                {
                    try { NetworkSafety.AssertSupportedEgress(); }
                    catch (Exception ex)
                    {
                        state.Error = "Protection topology could not be verified. " + ex.Message;
                    }
                }
                return state;
            }
            catch (FirewallProtectionException)
            {
                FirewallRuleState stored = FirewallManager.GetStoredRuleState();
                return new WidgetState
                {
                    Connected = connected,
                    ConnectionAmbiguous = ambiguous,
                    ConnectionHandle = connectionHandle,
                    TunnelInterfaceIndex = tunnelInterfaceIndex,
                    FirewallProtectionOff = true,
                    ManagedRulesPresent = stored.Found > 0,
                    KillSwitchIncomplete = stored.Found > 0
                };
            }
        }

        private void UpdateStatus()
        {
            if (IsActionRunning) return;
            UpdateCurrentServerLabel();
            if (previewState == null)
            {
                if (monitoringEnabled)
                {
                    QueueMonitoringCycle(true);
                    RefreshTelemetryLabel();
                    return;
                }

                try
                {
                    WidgetState state = ReadState();
                    ResetActionLabels();
                    bool unavailable = !string.IsNullOrEmpty(state.Error);
                    ApplyControlState(unavailable ? null : state);
                    ApplyDisplayState(
                        state.ConnectionAmbiguous ? WidgetDisplayState.Unavailable : GetDisplayState(state),
                        state);
                }
                catch
                {
                    ResetActionLabels();
                    ApplyControlState(null);
                    ApplyDisplayState(WidgetDisplayState.Unavailable, null);
                }
                SetTelemetryDisplay(
                    "MONITOR OFF | CLICK LIVE MONITOR TO START",
                    Color.FromArgb(132, 139, 151));
                return;
            }

            try
            {
                WidgetState state = ReadState();
                ResetActionLabels();
                bool unavailable = !string.IsNullOrEmpty(state.Error);
                ApplyControlState(unavailable ? null : state);
                ApplyDisplayState(state.PreviewDisplayState ?? GetDisplayState(state), state);
                ApplyPreviewTelemetry(state);
            }
            catch
            {
                ResetActionLabels();
                ApplyControlState(null);
                ApplyDisplayState(WidgetDisplayState.Unavailable, null);
                ApplyPreviewTelemetry(null);
            }
        }

        /// <summary>
        /// Refreshes the read-only active-server indicator without replacing a pending hostname
        /// that the user is editing in the selector.
        /// </summary>
        private void UpdateCurrentServerLabel()
        {
            currentServerLabel.Text = "CURRENT: " + AppConfig.ServerHost;
        }

        /// <summary>
        /// Starts or stops every periodic traffic, latency, route, and public-IP probe. Manual status
        /// refresh remains available while monitoring is off.
        /// </summary>
        private void SetMonitoringEnabled(bool enabled)
        {
            if (previewState != null || monitoringStopped) return;
            if (enabled && IsActionRunning) return;
            Interlocked.Increment(ref monitoringEpoch);
            monitoringEnabled = enabled;
            UpdateTrayToolTip();
            if (enabled)
            {
                lock (monitoringSync)
                {
                    leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
                    nextLeakProbeAllowedUtc = DateTime.MinValue;
                }
                UpdateMonitoringTimerInterval();
                timer.Start();
                Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                QueueMonitoringCycle(true);
                RefreshTelemetryLabel();
                return;
            }

            timer.Stop();
            lock (monitoringSync)
            {
                protectionGeneration++;
                monitoredConnectionVerified = false;
                monitoredConnectionObservedUtc = DateTime.MinValue;
                monitoredTrafficReady = false;
                previousTrafficSample = null;
                monitoredPingAvailable = false;
                monitoredPingSucceeded = false;
                leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.Disabled);
                nextLeakProbeAllowedUtc = DateTime.MinValue;
            }
            CancelLeakProbe();
            SetTelemetryDisplay(
                "MONITOR OFF | CLICK LIVE MONITOR TO START",
                Color.FromArgb(132, 139, 151));
            SetLeakDisplay(
                "ROUTE CHECK OFF",
                Color.FromArgb(132, 139, 151),
                "IP LEAK CHECK OFF",
                Color.FromArgb(132, 139, 151));
            UpdateStatus();
        }

        /// <summary>
        /// Restarts monitoring after a serialized VPN action and forces the cached protection state
        /// to be replaced before another protected result is displayed.
        /// </summary>
        private void ResumeMonitoringAfterAction()
        {
            if (monitoringStopped) return;
            monitoringPausedForAction = false;
            if (!monitoringEnabled) return;
            lock (monitoringSync)
            {
                nextLeakProbeAllowedUtc = DateTime.MinValue;
                leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
            }
            UpdateMonitoringTimerInterval();
            Interlocked.Exchange(ref forceStateRefreshRequested, 1);
            timer.Start();
            QueueMonitoringCycle(true);
        }

        /// <summary>
        /// Samples quickly while the telemetry is visible and backs off while the window is hidden in
        /// the system tray, where sub-second traffic updates cannot be seen.
        /// </summary>
        private void UpdateMonitoringTimerInterval()
        {
            timer.Interval = Visible && WindowState != FormWindowState.Minimized
                ? VisibleMonitoringIntervalMilliseconds
                : BackgroundMonitoringIntervalMilliseconds;
        }

        /// <summary>
        /// Queues one serialized monitoring pass. Firewall and topology checks are cached for five
        /// seconds, while inexpensive exact-handle RAS counters run once a second when visible and
        /// once every five seconds in the system tray.
        /// </summary>
        private void QueueMonitoringCycle(bool forceStateRefresh)
        {
            if (previewState != null || !monitoringEnabled || monitoringStopped || monitoringPausedForAction ||
                IsDisposed || Disposing) return;
            if (forceStateRefresh) Interlocked.Exchange(ref forceStateRefreshRequested, 1);
            if (Interlocked.CompareExchange(ref monitoringWorkerActive, 1, 0) != 0) return;
            long expectedEpoch = Interlocked.Read(ref monitoringEpoch);

            ThreadPool.QueueUserWorkItem(delegate
            {
                bool stateRefreshed = false;
                try
                {
                    stateRefreshed = CollectMonitoringSample(expectedEpoch);
                }
                catch
                {
                    stateRefreshed = CacheUnavailableMonitoringState(expectedEpoch);
                }
                finally
                {
                    Interlocked.Exchange(ref monitoringWorkerActive, 0);
                }
                PostMonitoringUpdate(stateRefreshed, expectedEpoch);
            });
        }

        private bool IsMonitoringCycleCurrent(long expectedEpoch)
        {
            return monitoringEnabled && !monitoringStopped && !monitoringPausedForAction &&
                Interlocked.Read(ref monitoringEpoch) == expectedEpoch;
        }

        private bool CollectMonitoringSample(long expectedEpoch)
        {
            if (!IsMonitoringCycleCurrent(expectedEpoch)) return false;
            DateTime now = DateTime.UtcNow;
            bool force = Interlocked.Exchange(ref forceStateRefreshRequested, 0) != 0;
            if (!IsMonitoringCycleCurrent(expectedEpoch))
            {
                if (force) Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                return false;
            }
            bool refreshState;
            lock (monitoringSync)
            {
                if (!IsMonitoringCycleCurrent(expectedEpoch))
                {
                    if (force) Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                    return false;
                }
                refreshState = force || monitoredState == null || now >= nextStateRefreshUtc;
                if (refreshState) nextStateRefreshUtc = now.Add(ProtectionRefreshInterval);
            }

            if (refreshState)
            {
                WidgetState observed;
                try { observed = ReadState(); }
                catch
                {
                    observed = new WidgetState
                    {
                        Error = "Windows could not verify VPN and firewall protection."
                    };
                }
                if (!IsMonitoringCycleCurrent(expectedEpoch) ||
                    !CacheObservedState(observed, DateTime.UtcNow, expectedEpoch))
                    return false;
            }

            WidgetState state;
            DateTime stateObservedUtc;
            lock (monitoringSync)
            {
                if (!IsMonitoringCycleCurrent(expectedEpoch)) return false;
                state = monitoredState;
                stateObservedUtc = monitoredStateObservedUtc;
            }

            if (state == null || !state.Connected || state.ConnectionHandle == IntPtr.Zero ||
                DateTime.UtcNow - stateObservedUtc > ProtectionFreshnessWindow)
            {
                if (IsMonitoringCycleCurrent(expectedEpoch)) InvalidateConnectionVerification();
                return refreshState;
            }

            try
            {
                if (!IsMonitoringCycleCurrent(expectedEpoch)) return refreshState;
                if (!RasManager.IsConnectionEstablished(state.ConnectionHandle))
                    throw new InvalidOperationException("The VPN tunnel is not fully connected.");
                RasConnectionStatistics statistics = RasManager.ReadConnectionStatistics(state.ConnectionHandle);
                if (!CacheTrafficSample(state.ConnectionHandle, statistics, expectedEpoch))
                    return refreshState;
                if (!IsMonitoringCycleCurrent(expectedEpoch)) return refreshState;
                QueuePingIfEligible();
                QueueLeakProbeIfEligible();
            }
            catch
            {
                if (IsMonitoringCycleCurrent(expectedEpoch))
                {
                    InvalidateConnectionVerification();
                    Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                }
            }
            return refreshState;
        }

        private bool CacheObservedState(WidgetState state, DateTime observedUtc, long expectedEpoch)
        {
            bool connectionChanged;
            lock (monitoringSync)
            {
                if (!IsMonitoringCycleCurrent(expectedEpoch)) return false;
                bool oldProtected = IsFullyProtected(monitoredState);
                IntPtr oldHandle = monitoredState == null ? IntPtr.Zero : monitoredState.ConnectionHandle;
                uint oldInterfaceIndex = monitoredState == null ? 0 : monitoredState.TunnelInterfaceIndex;
                bool newProtected = IsFullyProtected(state);
                connectionChanged = oldProtected != newProtected || oldHandle != state.ConnectionHandle ||
                    oldInterfaceIndex != state.TunnelInterfaceIndex;
                if (connectionChanged)
                {
                    protectionGeneration++;
                    nextLeakProbeAllowedUtc = DateTime.MinValue;
                    leakMonitorSnapshot = LeakMonitorSnapshot.Create(
                        newProtected ? LeakCheckState.Checking : LeakCheckState.WaitingForProtection);
                }

                monitoredState = state;
                monitoredStateObservedUtc = observedUtc;
                if (!newProtected)
                {
                    monitoredPingAvailable = false;
                    monitoredPingSucceeded = false;
                }
                if (oldHandle != state.ConnectionHandle || !state.Connected)
                {
                    previousTrafficSample = null;
                    monitoredTrafficReady = false;
                    monitoredConnectionVerified = false;
                    monitoredConnectionObservedUtc = DateTime.MinValue;
                }
            }
            if (connectionChanged) CancelLeakProbe();
            return true;
        }

        private bool CacheUnavailableMonitoringState(long expectedEpoch)
        {
            return CacheObservedState(
                new WidgetState { Error = "Windows could not verify VPN and firewall protection." },
                DateTime.UtcNow,
                expectedEpoch);
        }

        /// <summary>
        /// Converts modular 32-bit RAS byte-counter deltas into decimal megabits per second. A new
        /// handle or reduced connection duration is treated as a reset and requires a warm-up sample.
        /// </summary>
        private bool CacheTrafficSample(
            IntPtr handle,
            RasConnectionStatistics statistics,
            long expectedEpoch)
        {
            long timestamp = Stopwatch.GetTimestamp();
            TrafficCounterSample current = new TrafficCounterSample
            {
                ConnectionHandle = handle,
                BytesSent = statistics.BytesSent,
                BytesReceived = statistics.BytesReceived,
                ConnectDurationMilliseconds = statistics.ConnectDurationMilliseconds,
                Timestamp = timestamp
            };

            lock (monitoringSync)
            {
                if (!IsMonitoringCycleCurrent(expectedEpoch)) return false;
                TrafficCounterSample previous = previousTrafficSample;
                monitoredTrafficReady = false;
                if (previous != null && previous.ConnectionHandle == handle &&
                    statistics.ConnectDurationMilliseconds >= previous.ConnectDurationMilliseconds)
                {
                    double seconds = (timestamp - previous.Timestamp) / (double)Stopwatch.Frequency;
                    if (seconds >= 0.05 && seconds <= 10.0)
                    {
                        uint receivedDelta = unchecked(statistics.BytesReceived - previous.BytesReceived);
                        uint sentDelta = unchecked(statistics.BytesSent - previous.BytesSent);
                        monitoredDownloadMbps = receivedDelta * 8.0 / seconds / 1000000.0;
                        monitoredUploadMbps = sentDelta * 8.0 / seconds / 1000000.0;
                        monitoredTrafficReady = true;
                    }
                }

                previousTrafficSample = current;
                monitoredConnectionVerified = true;
                monitoredConnectionObservedUtc = DateTime.UtcNow;
            }
            return true;
        }

        private void InvalidateConnectionVerification()
        {
            bool connectionWasVerified;
            lock (monitoringSync)
            {
                connectionWasVerified = monitoredConnectionVerified;
                if (connectionWasVerified)
                {
                    protectionGeneration++;
                    nextLeakProbeAllowedUtc = DateTime.MinValue;
                    leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
                }
                monitoredConnectionVerified = false;
                monitoredConnectionObservedUtc = DateTime.MinValue;
                monitoredTrafficReady = false;
                previousTrafficSample = null;
                monitoredPingAvailable = false;
                monitoredPingSucceeded = false;
            }
            if (connectionWasVerified) CancelLeakProbe();
        }

        /// <summary>
        /// Starts at most one ICMP request every five seconds, only after fresh VPN, firewall, topology, and
        /// exact-handle checks all pass. A generation and handle guard discards late replies.
        /// </summary>
        private void QueuePingIfEligible()
        {
            if (!monitoringEnabled || monitoringPausedForAction) return;
            DateTime now = DateTime.UtcNow;
            long generation;
            IntPtr handle;
            uint tunnelInterfaceIndex;
            lock (monitoringSync)
            {
                if (!IsFullyProtected(monitoredState) || !monitoredConnectionVerified ||
                    now - monitoredStateObservedUtc > ProtectionFreshnessWindow ||
                    now - monitoredConnectionObservedUtc > ConnectionFreshnessWindow ||
                    now < nextPingAllowedUtc)
                    return;
                if (Interlocked.CompareExchange(ref pingWorkerActive, 1, 0) != 0) return;
                nextPingAllowedUtc = now.Add(PingInterval);
                generation = protectionGeneration;
                handle = monitoredState.ConnectionHandle;
                tunnelInterfaceIndex = monitoredState.TunnelInterfaceIndex;
            }

            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    bool succeeded = false;
                    long milliseconds = 0;
                    try
                    {
                        using (Ping ping = new Ping())
                        {
                            PingReply reply = ping.Send(IPAddress.Parse("1.1.1.1"), 750);
                            succeeded = reply != null && reply.Status == IPStatus.Success;
                            if (succeeded) milliseconds = reply.RoundtripTime;
                        }
                    }
                    catch { }

                    bool sameConnectionStillEstablished = false;
                    try
                    {
                        List<RasConnection> currentConnections = RasManager.GetConnections();
                        RasConnection[] currentMatches = currentConnections
                            .Where(c => string.Equals(
                                c.Name,
                                AppConfig.VpnName,
                                StringComparison.OrdinalIgnoreCase))
                            .ToArray();
                        sameConnectionStillEstablished = currentConnections.Count == 1 &&
                            currentMatches.Length == 1 &&
                            currentMatches[0].Handle == handle &&
                            RasManager.GetConnectionInterfaceIndex(handle) == tunnelInterfaceIndex &&
                            RasManager.IsConnectionEstablished(handle);
                    }
                    catch { }

                    bool protectionStillValid = false;
                    if (sameConnectionStillEstablished)
                    {
                        try
                        {
                            FirewallRuleState currentRules = FirewallManager.GetRuleState();
                            NetworkSafety.AssertSupportedEgress();
                            protectionStillValid = currentRules.Valid == AppConfig.RuleNames.Length;
                        }
                        catch { }
                    }

                    bool forceRefreshAfterProbe = false;
                    lock (monitoringSync)
                    {
                        if (monitoringEnabled && sameConnectionStillEstablished && protectionStillValid &&
                            generation == protectionGeneration && IsFullyProtected(monitoredState) &&
                            monitoredState.ConnectionHandle == handle &&
                            monitoredState.TunnelInterfaceIndex == tunnelInterfaceIndex && monitoredConnectionVerified)
                        {
                            monitoredPingAvailable = true;
                            monitoredPingSucceeded = succeeded;
                            monitoredPingMilliseconds = milliseconds;
                            monitoredPingObservedUtc = DateTime.UtcNow;
                        }
                        else if (monitoringEnabled && generation == protectionGeneration && monitoredState != null &&
                            monitoredState.ConnectionHandle == handle &&
                            monitoredState.TunnelInterfaceIndex == tunnelInterfaceIndex)
                        {
                            protectionGeneration++;
                            monitoredConnectionVerified = false;
                            monitoredConnectionObservedUtc = DateTime.MinValue;
                            monitoredTrafficReady = false;
                            previousTrafficSample = null;
                            monitoredPingAvailable = false;
                            monitoredPingSucceeded = false;
                            forceRefreshAfterProbe = true;
                        }
                    }
                    if (forceRefreshAfterProbe)
                        Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                }
                finally
                {
                    Interlocked.Exchange(ref pingWorkerActive, 0);
                    PostMonitoringUpdate(false);
                }
            });
        }

        /// <summary>
        /// Starts at most one low-frequency public-IP sweep after the exact RAS handle and its
        /// tunnel interface index have both been freshly verified. Late results are rejected by
        /// generation, handle, interface, firewall, topology, and connection checks.
        /// </summary>
        private void QueueLeakProbeIfEligible()
        {
            if (!monitoringEnabled || monitoringStopped || monitoringPausedForAction) return;
            DateTime now = DateTime.UtcNow;
            long generation;
            IntPtr handle;
            uint tunnelInterfaceIndex;
            CancellationTokenSource cancellation;

            lock (monitoringSync)
            {
                if (!IsFullyProtected(monitoredState) || !monitoredConnectionVerified ||
                    now - monitoredStateObservedUtc > ProtectionFreshnessWindow ||
                    now - monitoredConnectionObservedUtc > ConnectionFreshnessWindow)
                {
                    if (Interlocked.CompareExchange(ref leakProbeWorkerActive, 0, 0) == 0)
                        leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
                    return;
                }
                if (now < nextLeakProbeAllowedUtc) return;
                if (Interlocked.CompareExchange(ref leakProbeWorkerActive, 1, 0) != 0) return;

                generation = protectionGeneration;
                handle = monitoredState.ConnectionHandle;
                tunnelInterfaceIndex = monitoredState.TunnelInterfaceIndex;
                nextLeakProbeAllowedUtc = now.Add(LeakProbeInterval);
                leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.Checking);
                cancellation = new CancellationTokenSource();
                leakProbeCancellation = cancellation;
            }

            PostMonitoringUpdate(false);
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    LeakProbeSweepResult sweep = PublicIpLeakProbe.Run(
                        tunnelInterfaceIndex,
                        cancellation.Token);
                    if (cancellation.IsCancellationRequested) return;

                    bool contextStillValid = IsLeakProbeContextStillValid(handle, tunnelInterfaceIndex);
                    lock (monitoringSync)
                    {
                        bool sameGeneration = monitoringEnabled && !monitoringStopped &&
                            generation == protectionGeneration && IsFullyProtected(monitoredState) &&
                            monitoredState.ConnectionHandle == handle &&
                            monitoredState.TunnelInterfaceIndex == tunnelInterfaceIndex &&
                            monitoredConnectionVerified;
                        if (sameGeneration && contextStillValid)
                        {
                            leakMonitorSnapshot = LeakMonitorSnapshot.FromSweep(sweep);
                        }
                        else if (sameGeneration)
                        {
                            protectionGeneration++;
                            monitoredConnectionVerified = false;
                            monitoredConnectionObservedUtc = DateTime.MinValue;
                            monitoredTrafficReady = false;
                            previousTrafficSample = null;
                            monitoredPingAvailable = false;
                            monitoredPingSucceeded = false;
                            leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.WaitingForProtection);
                            nextLeakProbeAllowedUtc = DateTime.MinValue;
                            Interlocked.Exchange(ref forceStateRefreshRequested, 1);
                        }
                    }
                }
                catch (Exception)
                {
                    if (!cancellation.IsCancellationRequested)
                    {
                        lock (monitoringSync)
                        {
                            if (monitoringEnabled && !monitoringStopped &&
                                generation == protectionGeneration && IsFullyProtected(monitoredState) &&
                                monitoredState.ConnectionHandle == handle &&
                                monitoredState.TunnelInterfaceIndex == tunnelInterfaceIndex)
                            {
                                leakMonitorSnapshot = LeakMonitorSnapshot.Create(LeakCheckState.CheckIncomplete);
                            }
                        }
                    }
                }
                finally
                {
                    lock (monitoringSync)
                    {
                        if (ReferenceEquals(leakProbeCancellation, cancellation))
                            leakProbeCancellation = null;
                    }
                    cancellation.Dispose();
                    Interlocked.Exchange(ref leakProbeWorkerActive, 0);
                    PostMonitoringUpdate(false);
                }
            });
        }

        private static bool IsLeakProbeContextStillValid(IntPtr handle, uint tunnelInterfaceIndex)
        {
            try
            {
                List<RasConnection> currentConnections = RasManager.GetConnections();
                RasConnection[] currentMatches = currentConnections
                    .Where(connection => string.Equals(
                        connection.Name,
                        AppConfig.VpnName,
                        StringComparison.OrdinalIgnoreCase))
                    .ToArray();
                if (currentConnections.Count != 1 || currentMatches.Length != 1 ||
                    currentMatches[0].Handle != handle ||
                    RasManager.GetConnectionInterfaceIndex(handle) != tunnelInterfaceIndex ||
                    !RasManager.IsConnectionEstablished(handle))
                    return false;

                FirewallRuleState currentRules = FirewallManager.GetRuleState();
                NetworkSafety.AssertSupportedEgress();
                return currentRules.Valid == AppConfig.RuleNames.Length;
            }
            catch
            {
                return false;
            }
        }

        private void CancelLeakProbe()
        {
            CancellationTokenSource cancellation;
            lock (monitoringSync)
            {
                cancellation = leakProbeCancellation;
                leakProbeCancellation = null;
            }
            if (cancellation == null) return;
            try { cancellation.Cancel(); }
            catch (ObjectDisposedException) { }
        }

        private static bool IsFullyProtected(WidgetState state)
        {
            return state != null && string.IsNullOrEmpty(state.Error) && state.Connected &&
                !state.ConnectionAmbiguous && state.ConnectionHandle != IntPtr.Zero &&
                state.TunnelInterfaceIndex != 0 &&
                state.KillSwitchActive && !state.KillSwitchIncomplete && !state.FirewallProtectionOff;
        }

        private void PostMonitoringUpdate(bool stateRefreshed)
        {
            PostMonitoringUpdate(stateRefreshed, Interlocked.Read(ref monitoringEpoch));
        }

        private void PostMonitoringUpdate(bool stateRefreshed, long expectedEpoch)
        {
            if (!monitoringEnabled || monitoringStopped || IsDisposed || Disposing ||
                monitoringPausedForAction || IsActionRunning || !IsHandleCreated) return;
            if (stateRefreshed && IsMonitoringCycleCurrent(expectedEpoch))
            {
                Interlocked.Exchange(ref monitoringStateUiRefreshEpoch, expectedEpoch);
                Interlocked.Exchange(ref monitoringStateUiRefreshRequested, 1);
            }
            if (Interlocked.CompareExchange(ref monitoringUiUpdatePending, 1, 0) != 0) return;
            try
            {
                BeginInvoke(new Action(delegate
                {
                    Interlocked.Exchange(ref monitoringUiUpdatePending, 0);
                    bool refreshStateUi = Interlocked.Exchange(
                        ref monitoringStateUiRefreshRequested,
                        0) != 0;
                    long refreshEpoch = Interlocked.Read(ref monitoringStateUiRefreshEpoch);
                    if (!monitoringEnabled || monitoringStopped || monitoringPausedForAction ||
                        IsActionRunning || IsDisposed || Disposing) return;
                    if (refreshStateUi && IsMonitoringCycleCurrent(refreshEpoch)) ApplyMonitoredState();
                    RefreshTelemetryLabel();
                }));
            }
            catch (InvalidOperationException)
            {
                Interlocked.Exchange(ref monitoringUiUpdatePending, 0);
            }
        }

        private void ApplyMonitoredState()
        {
            WidgetState state;
            lock (monitoringSync) state = monitoredState;
            ResetActionLabels();
            bool unavailable = state == null || !string.IsNullOrEmpty(state.Error);
            ApplyControlState(unavailable ? null : state);
            WidgetDisplayState displayState = state != null && state.ConnectionAmbiguous
                ? WidgetDisplayState.Unavailable
                : GetDisplayState(state);
            ApplyDisplayState(displayState, state);
        }

        private void ApplyPreviewTelemetry(WidgetState state)
        {
            bool protectedState = state != null && state.Connected && state.KillSwitchActive &&
                !state.KillSwitchIncomplete && !state.FirewallProtectionOff;
            SetTelemetryDisplay(
                protectedState && state.PreviewTelemetryAvailable
                    ? "PROTECTED | LATENCY " + state.PreviewLatencyMilliseconds.ToString(CultureInfo.InvariantCulture) +
                      " ms | D " + state.PreviewDownloadMbps.ToString("0.0", CultureInfo.InvariantCulture) +
                      " / U " + state.PreviewUploadMbps.ToString("0.0", CultureInfo.InvariantCulture) + " Mbps"
                    : protectedState
                    ? "PROTECTED | LATENCY -- | D -- / U -- Mbps"
                    : "NOT PROTECTED | LATENCY OFF | D -- / U -- Mbps",
                protectedState
                    ? Color.FromArgb(244, 196, 75)
                    : Color.FromArgb(239, 75, 79));
            SetLeakDisplay(
                protectedState
                    ? "ROUTE: VPN TUNNEL | IPv4: REACHABLE | IPv6: NO RESPONSE"
                    : "ROUTE CHECK: FULL PROTECTION REQUIRED",
                protectedState
                    ? Color.FromArgb(57, 206, 136)
                    : Color.FromArgb(239, 75, 79),
                protectedState
                    ? "IP LEAK CHECK: NO LEAK SIGNALS"
                    : "IP LEAK CHECK: PAUSED",
                protectedState
                    ? Color.FromArgb(57, 206, 136)
                    : Color.FromArgb(239, 75, 79));
        }

        private void RefreshTelemetryLabel()
        {
            if (previewState != null) return;
            if (monitoringPausedForAction || IsActionRunning) return;
            if (!monitoringEnabled)
            {
                SetTelemetryDisplay(
                    "MONITOR OFF | CLICK LIVE MONITOR TO START",
                    Color.FromArgb(132, 139, 151));
                SetLeakDisplay(
                    "ROUTE CHECK OFF",
                    Color.FromArgb(132, 139, 151),
                    "IP LEAK CHECK OFF",
                    Color.FromArgb(132, 139, 151));
                return;
            }

            WidgetState state;
            DateTime stateObservedUtc;
            bool connectionVerified;
            DateTime connectionObservedUtc;
            bool trafficReady;
            double downloadMbps;
            double uploadMbps;
            bool pingAvailable;
            bool pingSucceeded;
            long pingMilliseconds;
            DateTime pingObservedUtc;
            LeakMonitorSnapshot leakSnapshot;
            lock (monitoringSync)
            {
                state = monitoredState;
                stateObservedUtc = monitoredStateObservedUtc;
                connectionVerified = monitoredConnectionVerified;
                connectionObservedUtc = monitoredConnectionObservedUtc;
                trafficReady = monitoredTrafficReady;
                downloadMbps = monitoredDownloadMbps;
                uploadMbps = monitoredUploadMbps;
                pingAvailable = monitoredPingAvailable;
                pingSucceeded = monitoredPingSucceeded;
                pingMilliseconds = monitoredPingMilliseconds;
                pingObservedUtc = monitoredPingObservedUtc;
                leakSnapshot = leakMonitorSnapshot;
            }

            DateTime now = DateTime.UtcNow;
            bool stateFresh = now - stateObservedUtc <= ProtectionFreshnessWindow;
            bool connectionFresh = connectionVerified &&
                now - connectionObservedUtc <= ConnectionFreshnessWindow;
            bool protectedStatusStale = IsFullyProtected(state) && !connectionFresh;
            if (!stateFresh || state == null || protectedStatusStale)
            {
                ApplyControlState(null);
                bool firstObservationPending = state == null || stateObservedUtc == DateTime.MinValue;
                ApplyStatus(
                    firstObservationPending
                        ? Color.FromArgb(84, 150, 235)
                        : Color.FromArgb(239, 75, 79),
                    firstObservationPending ? "CHECKING STATUS" : "STATUS CHECK DELAYED",
                    firstObservationPending
                        ? "Reading VPN and kill-switch protection..."
                        : "Live protection status is stale. Click REFRESH.",
                    firstObservationPending ? "Checking status" : "Status check delayed");
            }
            else
            {
                bool stateUnavailable = state.ConnectionAmbiguous || !string.IsNullOrEmpty(state.Error);
                ApplyControlState(stateUnavailable ? null : state);
                bool tunnelIdentityUnavailable = string.IsNullOrEmpty(state.Error) &&
                    !state.ConnectionAmbiguous && state.Connected && state.KillSwitchActive &&
                    !state.KillSwitchIncomplete && !state.FirewallProtectionOff &&
                    state.TunnelInterfaceIndex == 0;
                bool exposureSignal = leakSnapshot != null &&
                    leakSnapshot.State == LeakCheckState.ExposureDetected;
                if (exposureSignal)
                {
                    ApplyStatus(
                        Color.FromArgb(239, 75, 79),
                        "EXPOSURE SIGNAL DETECTED",
                        "The live route or IP check needs attention.",
                        "Exposure signal detected");
                }
                else if (tunnelIdentityUnavailable)
                {
                    ApplyStatus(
                        Color.FromArgb(244, 178, 65),
                        "LIVE VERIFY UNAVAILABLE",
                        "VPN is connected, but its tunnel route could not be verified.",
                        "Live verification unavailable");
                }
                else
                {
                    ApplyDisplayState(
                        state.ConnectionAmbiguous
                            ? WidgetDisplayState.Unavailable
                            : GetDisplayState(state),
                        state);
                }
            }
            if (!stateFresh || state == null || !IsFullyProtected(state) || !connectionFresh)
            {
                string reason;
                if (!stateFresh || state == null)
                    reason = state == null ? "CHECKING" : "STATUS STALE";
                else if (!string.IsNullOrEmpty(state.Error))
                    reason = "STATUS UNAVAILABLE";
                else if (state.ConnectionAmbiguous)
                    reason = "RAS AMBIGUOUS";
                else if (!state.Connected)
                    reason = "VPN OFF";
                else if (state.KillSwitchActive && !state.KillSwitchIncomplete &&
                    !state.FirewallProtectionOff && state.TunnelInterfaceIndex == 0)
                    reason = "TUNNEL ID UNAVAILABLE";
                else if (!IsFullyProtected(state))
                    reason = "VPN NOT PROTECTED";
                else
                    reason = "VERIFYING VPN";
                SetTelemetryDisplay(
                    reason + " | LATENCY OFF | D -- / U -- Mbps",
                    Color.FromArgb(239, 75, 79));
                RefreshLeakDisplay(leakSnapshot, false);
                return;
            }

            string traffic = trafficReady
                ? "D " + FormatMegabitsPerSecond(downloadMbps) + " / U " +
                    FormatMegabitsPerSecond(uploadMbps) + " Mbps"
                : "D -- / U -- Mbps";
            bool pingFresh = pingAvailable && now - pingObservedUtc <= PingFreshnessWindow;
            if (leakSnapshot != null && leakSnapshot.State == LeakCheckState.ExposureDetected)
            {
                string exposurePing = pingFresh && pingSucceeded
                    ? string.Format("LAT {0} ms", pingMilliseconds)
                    : pingFresh ? "LAT TIMEOUT" : "LAT --";
                SetTelemetryDisplay(
                    "EXPOSURE | " + exposurePing + " | " + traffic,
                    Color.FromArgb(239, 75, 79));
                RefreshLeakDisplay(leakSnapshot, true);
                return;
            }
            if (!pingFresh || !pingSucceeded)
            {
                string pingText = pingFresh ? "LATENCY TIMEOUT" : "LATENCY --";
                SetTelemetryDisplay(
                    "PROTECTED | " + pingText + " | " + traffic,
                    Color.FromArgb(244, 178, 65));
                RefreshLeakDisplay(leakSnapshot, true);
                return;
            }

            Color telemetryColor = pingMilliseconds <= 80
                ? Color.FromArgb(57, 206, 136)
                : pingMilliseconds <= 160
                    ? Color.FromArgb(244, 196, 75)
                    : pingMilliseconds <= 300
                        ? Color.FromArgb(244, 178, 65)
                        : Color.FromArgb(239, 75, 79);
            SetTelemetryDisplay(
                string.Format("PROTECTED | LATENCY {0} ms | {1}", pingMilliseconds, traffic),
                telemetryColor);
            RefreshLeakDisplay(leakSnapshot, true);
        }

        private static string FormatMegabitsPerSecond(double value)
        {
            if (double.IsNaN(value) || double.IsInfinity(value) || value < 0) return "--";
            if (value >= 9999.5) return "9999+";
            return value >= 1000
                ? value.ToString("0.0", CultureInfo.InvariantCulture)
                : value.ToString("0.00", CultureInfo.InvariantCulture);
        }

        private void RefreshLeakDisplay(LeakMonitorSnapshot snapshot, bool fullyProtected)
        {
            if (!fullyProtected || snapshot == null ||
                snapshot.State == LeakCheckState.WaitingForProtection)
            {
                SetLeakDisplay(
                    "ROUTE CHECK: FULL PROTECTION REQUIRED",
                    Color.FromArgb(239, 75, 79),
                    "IP LEAK CHECK: PAUSED",
                    Color.FromArgb(239, 75, 79));
                return;
            }

            switch (snapshot.State)
            {
                case LeakCheckState.Checking:
                    SetLeakDisplay(
                        "ROUTE: CHECKING | IPv4: CHECKING | IPv6: CHECKING",
                        Color.FromArgb(84, 150, 235),
                        "IP LEAK CHECK: CHECKING",
                        Color.FromArgb(84, 150, 235));
                    return;
                case LeakCheckState.NoLeakSignals:
                    SetLeakDisplay(
                        "ROUTE: VPN TUNNEL | IPv4: REACHABLE | IPv6: NO RESPONSE",
                        Color.FromArgb(57, 206, 136),
                        "IP LEAK CHECK: NO LEAK SIGNALS",
                        Color.FromArgb(57, 206, 136));
                    return;
                case LeakCheckState.ExposureDetected:
                    string route = snapshot.RouteState == ManagedRouteState.BypassRoute
                        ? "BYPASS SIGNAL"
                        : snapshot.RouteState == ManagedRouteState.ViaManagedTunnel
                            ? "VPN TUNNEL"
                            : "UNAVAILABLE";
                    string ipv6 = snapshot.Ipv6ResponseReceived
                        ? "EXPOSED"
                        : "NO RESPONSE";
                    SetLeakDisplay(
                        "ROUTE: " + route + " | IPv4: " +
                            (snapshot.Ipv4ResponseReceived ? "RESPONDED" : "NO RESPONSE") +
                            " | IPv6: " + ipv6,
                        Color.FromArgb(239, 75, 79),
                        "IP LEAK CHECK: EXPOSURE SIGNAL DETECTED",
                        Color.FromArgb(239, 75, 79));
                    return;
                case LeakCheckState.CheckIncomplete:
                    SetLeakDisplay(
                        "ROUTE: INCOMPLETE | IPv4: " + GetProbeStatusText(snapshot.Ipv4Status) +
                            " | IPv6: " + GetProbeStatusText(snapshot.Ipv6Status),
                        Color.FromArgb(244, 178, 65),
                        "IP LEAK CHECK: INCOMPLETE - RETRYING",
                        Color.FromArgb(244, 178, 65));
                    return;
                default:
                    SetLeakDisplay(
                        "ROUTE CHECK OFF",
                        Color.FromArgb(132, 139, 151),
                        "IP LEAK CHECK OFF",
                        Color.FromArgb(132, 139, 151));
                    return;
            }
        }

        private static string GetProbeStatusText(PublicAddressProbeStatus status)
        {
            switch (status)
            {
                case PublicAddressProbeStatus.Success: return "REACHABLE";
                case PublicAddressProbeStatus.Timeout: return "TIMEOUT";
                case PublicAddressProbeStatus.Cancelled: return "CANCELLED";
                case PublicAddressProbeStatus.InvalidResponse: return "INVALID";
                case PublicAddressProbeStatus.Unavailable: return "N/A";
                default: return "NOT RUN";
            }
        }

        /// <summary>
        /// Avoids repainting the transparent telemetry label and themed background when its visual
        /// value did not change.
        /// </summary>
        private void SetTelemetryDisplay(string text, Color color)
        {
            if (!string.Equals(telemetryLabel.Text, text, StringComparison.Ordinal))
                telemetryLabel.Text = text;
            if (telemetryLabel.ForeColor.ToArgb() != color.ToArgb())
                telemetryLabel.ForeColor = color;
        }

        private void SetLeakDisplay(
            string routeText,
            Color routeColor,
            string leakText,
            Color leakColor)
        {
            if (!string.Equals(routeLabel.Text, routeText, StringComparison.Ordinal))
                routeLabel.Text = routeText;
            if (routeLabel.ForeColor.ToArgb() != routeColor.ToArgb())
                routeLabel.ForeColor = routeColor;
            if (!string.Equals(leakLabel.Text, leakText, StringComparison.Ordinal))
                leakLabel.Text = leakText;
            if (leakLabel.ForeColor.ToArgb() != leakColor.ToArgb())
                leakLabel.ForeColor = leakColor;
        }

        private static WidgetDisplayState GetDisplayState(WidgetState state)
        {
            if (state == null || !string.IsNullOrEmpty(state.Error))
                return WidgetDisplayState.Unavailable;
            if (state.FirewallProtectionOff)
                return WidgetDisplayState.FirewallProtectionOff;
            if (state.KillSwitchIncomplete)
                return WidgetDisplayState.ProtectionIncomplete;
            if (state.Connected && state.KillSwitchActive)
                return WidgetDisplayState.Protected;
            if (state.Connected)
                return WidgetDisplayState.ConnectedWithoutProtection;
            if (state.KillSwitchActive)
                return WidgetDisplayState.InternetBlocked;
            return WidgetDisplayState.Disconnected;
        }

        /// <summary>
        /// Maps each explicit display state to one complete set of widget and tray text, preventing
        /// contradictory labels from being assembled from independent booleans.
        /// </summary>
        private void ApplyDisplayState(WidgetDisplayState displayState, WidgetState state)
        {
            switch (displayState)
            {
                case WidgetDisplayState.Connecting:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "CONNECTING AND ARMING",
                        "Waiting for Windows and the VPN...", "Connecting and arming");
                    return;
                case WidgetDisplayState.ConnectingOnly:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "CONNECTING VPN ONLY",
                        "Kill-switch state is not being changed...", "Connecting VPN only");
                    return;
                case WidgetDisplayState.ArmingOnly:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "ARMING KILL SWITCH ONLY",
                        "VPN connection state is not being changed...", "Arming kill switch only");
                    return;
                case WidgetDisplayState.PreparingSignIn:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "ARMING PROTECTED SIGN-IN",
                        "Blocking normal internet before sign-in...", "Arming protected sign-in");
                    return;
                case WidgetDisplayState.Disconnecting:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "DISCONNECTING AND UNLOCKING",
                        "Restoring normal internet...", "Disconnecting and unlocking");
                    return;
                case WidgetDisplayState.DisconnectingOnly:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "DISCONNECTING VPN ONLY",
                        "Kill-switch state is not being changed...", "Disconnecting VPN only");
                    return;
                case WidgetDisplayState.UnlockingOnly:
                    ApplyStatus(Color.FromArgb(84, 150, 235), "REMOVING KILL SWITCH ONLY",
                        "VPN connection state is not being changed...", "Removing kill switch only");
                    return;
                case WidgetDisplayState.Protected:
                    ApplyStatus(Color.FromArgb(57, 206, 136), "CONNECTED AND PROTECTED",
                        "Switzerland VPN is active. The kill switch is armed.", "Connected and protected");
                    return;
                case WidgetDisplayState.ConnectedWithoutProtection:
                    ApplyStatus(Color.FromArgb(244, 178, 65), "CONNECTED, NOT PROTECTED",
                        "The VPN is active without kill-switch protection.", "Connected, not protected");
                    return;
                case WidgetDisplayState.InternetBlocked:
                    ApplyStatus(Color.FromArgb(239, 75, 79), "VPN DOWN - INTERNET BLOCKED",
                        "The kill switch is active. Use DISCONNECT + UNLOCK.", "VPN down - internet blocked");
                    return;
                case WidgetDisplayState.ProtectionIncomplete:
                    ApplyStatus(Color.FromArgb(239, 75, 79), "KILL SWITCH SETUP INCOMPLETE",
                        "Use DISCONNECT + UNLOCK, then rebuild protection.", "Setup incomplete");
                    return;
                case WidgetDisplayState.FirewallProtectionOff:
                    string firewallDetail = state != null && state.ManagedRulesPresent
                        ? "Firewall is off; saved kill-switch rules are inactive."
                        : "Windows Firewall is off. The kill switch cannot arm.";
                    ApplyStatus(Color.FromArgb(239, 75, 79), "FIREWALL PROTECTION OFF",
                        firewallDetail, "Firewall protection off");
                    return;
                default:
                    ApplyStatus(Color.FromArgb(239, 75, 79), "STATUS UNAVAILABLE",
                        "Protection status unavailable. Click REFRESH.", "Status unavailable");
                    return;
                case WidgetDisplayState.Disconnected:
                    ApplyStatus(Color.FromArgb(132, 139, 151), "DISCONNECTED",
                        "The VPN is off. Normal internet is available.", "Disconnected");
                    return;
            }
        }

        private void ApplyStatus(Color color, string status, string detail, string trayStatus)
        {
            statusPrefix.ForeColor = color;
            statusLabel.Text = status;
            statusLabel.ForeColor = Color.WhiteSmoke;
            detailLabel.Text = detail;
            lastTrayStatus = trayStatus;
            UpdateTrayToolTip();
        }

        /// <summary>
        /// Keeps the tray hover text useful while staying under the legacy Windows notification-icon
        /// text limit. The monitor state is included because it controls every live network probe.
        /// </summary>
        private void UpdateTrayToolTip()
        {
            string tip = "Switzerland VPN | MON: " + (monitoringEnabled ? "ON" : "OFF") +
                " | " + lastTrayStatus;
            trayIcon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        }

        private void HandleResize(object sender, EventArgs e)
        {
            if (WindowState == FormWindowState.Minimized)
            {
                ClearActiveToolTip();
                UpdateMonitoringTimerInterval();
                Hide();
                trayIcon.BalloonTipTitle = "Switzerland VPN";
                trayIcon.BalloonTipText = "Still running in the system tray.";
                trayIcon.BalloonTipIcon = ToolTipIcon.Info;
                trayIcon.ShowBalloonTip(1800);
            }
        }

        private void RestoreFromTray()
        {
            ClearActiveToolTip();
            Show();
            WindowState = FormWindowState.Normal;
            ClearActiveToolTip();
            UpdateMonitoringTimerInterval();
            Activate();
            BringToFront();
            Invalidate(true);
            Update();
            UpdateStatus();
        }

        /// <summary>
        /// Dismisses both automatic and manually displayed tooltips before a tray visibility
        /// transition so WinForms cannot retain an orphaned tooltip window over the restored form.
        /// </summary>
        private void ClearActiveToolTip()
        {
            toolTips.Hide(this);
            lastDisabledToolTipControl = null;
        }

        private void HandleClosing(object sender, FormClosingEventArgs e)
        {
            if (previewState != null) return;
            if (e.CloseReason == CloseReason.WindowsShutDown)
            {
                trayIcon.Visible = false;
                return;
            }

            if (updaterHandoffStarted)
            {
                monitoringStopped = true;
                monitoringEnabled = false;
                monitoringPausedForAction = true;
                CancelLeakProbe();
                timer.Stop();
                trayIcon.Visible = false;
                trayIcon.Dispose();
                return;
            }

            if (IsActionRunning)
            {
                MessageBox.Show(
                    "Wait for the current operation to finish before exiting.",
                    "Switzerland VPN",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                e.Cancel = true;
                return;
            }

            string warningMessage;
            try
            {
                warningMessage = GetExitWarningMessage(ReadState());
            }
            catch
            {
                warningMessage =
                    "VPN and kill-switch status could not be verified. Exit Switzerland VPN anyway?";
            }

            if (!string.IsNullOrEmpty(warningMessage))
            {
                DialogResult answer = MessageBox.Show(
                    warningMessage,
                    "Exit Switzerland VPN?",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2);
                if (answer != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }
            }

            monitoringStopped = true;
            monitoringEnabled = false;
            monitoringPausedForAction = true;
            CancelLeakProbe();
            timer.Stop();
            trayIcon.Visible = false;
            trayIcon.Dispose();
        }

        /// <summary>
        /// Returns an exit warning only when closing could leave a tunnel or traffic protection active,
        /// or when Windows cannot prove both are off. A verified disconnected and disarmed state exits silently.
        /// </summary>
        private static string GetExitWarningMessage(WidgetState state)
        {
            if (state == null || !string.IsNullOrEmpty(state.Error) || state.ConnectionAmbiguous)
                return "VPN and kill-switch status could not be verified. Exit Switzerland VPN anyway?";
            if (state.FirewallProtectionOff && state.ManagedRulesPresent)
            {
                return "WARNING: Saved kill-switch rules remain while Windows Firewall is off. They may block internet " +
                    "when Firewall is turned back on. Exit anyway?";
            }
            if (state.KillSwitchActive || state.KillSwitchIncomplete)
            {
                return "WARNING: The kill switch is armed or incomplete. If this app exits, internet may stay blocked. " +
                    "Exit anyway?";
            }
            if (state.Connected)
                return "Switzerland VPN is connected. Closing this app will not disconnect the VPN. Exit anyway?";
            return null;
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string previewName = GetArgument(args, "--preview-state");
            string previewOutput = GetArgument(args, "--preview-output");
            if (!string.IsNullOrEmpty(previewName) && !string.IsNullOrEmpty(previewOutput))
            {
                WidgetState preview = CreatePreview(previewName);
                using (VpnForm form = new VpnForm(preview))
                    form.RenderPreview(Path.GetFullPath(previewOutput));
                return;
            }

            if (args.Length == 2 && string.Equals(args[0], "--diagnostic-output", StringComparison.OrdinalIgnoreCase))
            {
                RunDiagnostics(args[1]);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--firewall-arm", StringComparison.OrdinalIgnoreCase))
            {
                RunAdministratorHelper(delegate
                {
                    if (args.Length != 2) throw new InvalidOperationException("The firewall helper received invalid arguments.");
                    FirewallManager.CreateRules(NetworkSafety.ParseValidatedIpv4List(args[1]));
                });
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--firewall-remove", StringComparison.OrdinalIgnoreCase))
            {
                RunAdministratorHelper(FirewallManager.RemoveRules);
                return;
            }

            if (args.Length > 0 && string.Equals(args[0], "--clear-default-credentials", StringComparison.OrdinalIgnoreCase))
            {
                RunAdministratorHelper(delegate { RasManager.ClearDefaultCredentials(AppConfig.VpnName); });
                return;
            }

            UpdateRecoveryLaunchResult recovery = PrivateUpdateRecoveryManager.StartPendingRecovery();
            if (recovery.State == UpdateRecoveryLaunchState.Started) return;
            if (recovery.State == UpdateRecoveryLaunchState.Failed)
            {
                MessageBox.Show(
                    recovery.ErrorMessage,
                    "Switzerland VPN Update Recovery",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            try
            {
                bool created;
                using (Mutex instance = new Mutex(
                    true,
                    "Global\\SwitzerlandVPNWidget-9F71DB12",
                    out created))
                {
                    if (!created)
                    {
                        MessageBox.Show(
                            "Switzerland VPN is already running in this or another Windows session. " +
                            "Use its system-tray icon or close that copy first.",
                            "Switzerland VPN",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                        return;
                    }

                    using (VpnForm form = new VpnForm(null))
                        Application.Run(form);
                }
            }
            catch (UnauthorizedAccessException)
            {
                ShowInstanceCoordinationError();
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                ShowInstanceCoordinationError();
            }
            catch (IOException)
            {
                ShowInstanceCoordinationError();
            }
        }

        private static void ShowInstanceCoordinationError()
        {
            MessageBox.Show(
                "Windows could not coordinate Switzerland VPN across user sessions. Another user may already have it " +
                "open. Close the other copy or sign out of the other session, then try again.",
                "Switzerland VPN Could Not Start",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }

        private static void RunAdministratorHelper(Action action)
        {
            if (!IsAdministrator())
            {
                Environment.ExitCode = 2;
                return;
            }

            try
            {
                action();
                Environment.ExitCode = 0;
            }
            catch
            {
                Environment.ExitCode = 2;
            }
        }

        private static void RunDiagnostics(string outputPath)
        {
            List<string> lines = new List<string>();
            try
            {
                FirewallManager.AssertFirewallAvailable();
                FirewallRuleState rules = FirewallManager.GetRuleState();
                List<RasConnection> connections = RasManager.GetConnections();
                IPAddress[] addresses = NetworkSafety.ResolveAndValidateServer(AppConfig.ServerHost);
                lines.Add("RESULT: PASS");
                lines.Add("PROCESS: " + Process.GetCurrentProcess().ProcessName + ".exe");
                lines.Add("FIREWALL: RUNNING AND ENABLED");
                lines.Add("MANAGED RULES FOUND: " + rules.Found);
                lines.Add("MANAGED RULES VALID: " + rules.Valid);
                lines.Add("VPN CONNECTED: " + connections.Any(c => string.Equals(c.Name, AppConfig.VpnName, StringComparison.OrdinalIgnoreCase)));
                lines.Add("ACTIVE RAS CONNECTIONS: " + connections.Count);
                lines.Add("SERVER: " + AppConfig.ServerHost);
                lines.Add("SERVER IPV4 COUNT: " + addresses.Length);
            }
            catch (Exception ex)
            {
                lines.Add("RESULT: FAIL");
                lines.Add("ERROR: " + ex.Message.Replace("\r", " ").Replace("\n", " "));
                Environment.ExitCode = 2;
            }

            File.WriteAllLines(Path.GetFullPath(outputPath), lines.ToArray());
        }

        private static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static string GetArgument(string[] args, string name)
        {
            for (int i = 0; i + 1 < args.Length; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return null;
        }

        private static WidgetState CreatePreview(string name)
        {
            switch (name.ToLowerInvariant())
            {
                case "disconnected": return new WidgetState();
                case "connecting": return new WidgetState { PreviewDisplayState = WidgetDisplayState.Connecting };
                case "protected": return new WidgetState { Connected = true, KillSwitchActive = true };
                case "working": return CreateWorkingPreview(24, 84.6, 18.2);
                case "working2": return CreateWorkingPreview(22, 86.1, 17.9);
                case "working3": return CreateWorkingPreview(25, 83.8, 18.4);
                case "unprotected": return new WidgetState { Connected = true };
                case "blocked": return new WidgetState { KillSwitchActive = true };
                case "incomplete": return new WidgetState { KillSwitchIncomplete = true };
                case "firewalloff": return new WidgetState
                {
                    FirewallProtectionOff = true,
                    ManagedRulesPresent = true,
                    KillSwitchIncomplete = true
                };
                case "firewalloff-empty": return new WidgetState { FirewallProtectionOff = true };
                case "error": return new WidgetState { Error = "Windows could not read the VPN or firewall status." };
                default: throw new ArgumentException("Unknown preview state: " + name);
            }
        }

        /// <summary>
        /// Creates a protected documentation-preview state with representative live-monitor values.
        /// These values are visual examples only and never enter the live monitoring path.
        /// </summary>
        private static WidgetState CreateWorkingPreview(long latencyMilliseconds, double downloadMbps, double uploadMbps)
        {
            return new WidgetState
            {
                Connected = true,
                KillSwitchActive = true,
                PreviewTelemetryAvailable = true,
                PreviewLatencyMilliseconds = latencyMilliseconds,
                PreviewDownloadMbps = downloadMbps,
                PreviewUploadMbps = uploadMbps
            };
        }

    }
}
