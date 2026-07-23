// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SwitzerlandVPN.ReleaseVerification
{
    internal enum VerificationStatus
    {
        Ready,
        Verifying,
        Passed,
        Failed
    }

    internal sealed class ReleaseFileSpec
    {
        internal ReleaseFileSpec(string displayName, string[] candidateNames, string expectedSha256)
        {
            DisplayName = displayName;
            CandidateNames = candidateNames;
            ExpectedSha256 = expectedSha256;
        }

        internal string DisplayName { get; private set; }
        internal string[] CandidateNames { get; private set; }
        internal string ExpectedSha256 { get; private set; }
    }

    internal sealed class FileVerificationResult
    {
        internal FileVerificationResult(string displayName, bool passed, string detail)
        {
            DisplayName = displayName;
            Passed = passed;
            Detail = detail;
        }

        internal string DisplayName { get; private set; }
        internal bool Passed { get; private set; }
        internal string Detail { get; private set; }
    }

    internal sealed class ReleaseVerificationResult
    {
        internal ReleaseVerificationResult(FileVerificationResult[] files)
        {
            Files = files;
            Passed = true;
            foreach (FileVerificationResult file in files)
            {
                if (!file.Passed)
                {
                    Passed = false;
                    break;
                }
            }
        }

        internal bool Passed { get; private set; }
        internal FileVerificationResult[] Files { get; private set; }
    }

    internal static class ReleaseVerifier
    {
        private static readonly ReleaseFileSpec[] ExpectedFiles =
        {
            new ReleaseFileSpec(
                "Distribution ZIP",
                BuildCandidateNames("Distribution"),
                EmbeddedReleaseManifest.DistributionSha256),
            new ReleaseFileSpec(
                "Source ZIP",
                BuildCandidateNames("Source"),
                EmbeddedReleaseManifest.SourceSha256)
        };

        /// <summary>
        /// Verifies the two release archives beside the verifier. Both the local build filenames
        /// and GitHub's dot-normalized asset filenames are accepted, but ambiguous duplicates fail.
        /// </summary>
        internal static ReleaseVerificationResult Verify(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory))
            {
                throw new ArgumentException("The release folder is missing.", "directory");
            }

            string normalizedDirectory = Path.GetFullPath(directory);
            List<FileVerificationResult> results = new List<FileVerificationResult>();
            foreach (ReleaseFileSpec spec in ExpectedFiles)
            {
                results.Add(VerifyFile(normalizedDirectory, spec));
            }
            return new ReleaseVerificationResult(results.ToArray());
        }

        private static string[] BuildCandidateNames(string packageKind)
        {
            string spaced = "Switzerland VPN " + packageKind + " " + EmbeddedReleaseManifest.Version + ".zip";
            return new[] { spaced, spaced.Replace(' ', '.') };
        }

        private static FileVerificationResult VerifyFile(string directory, ReleaseFileSpec spec)
        {
            try
            {
                List<string> matches = new List<string>();
                foreach (string candidateName in spec.CandidateNames)
                {
                    string candidatePath = Path.Combine(directory, candidateName);
                    if (File.Exists(candidatePath))
                    {
                        matches.Add(candidatePath);
                    }
                }

                if (matches.Count == 0)
                {
                    return new FileVerificationResult(
                        spec.DisplayName,
                        false,
                        "MISSING - keep this verifier beside both v" + EmbeddedReleaseManifest.Version + " ZIPs.");
                }
                if (matches.Count > 1)
                {
                    return new FileVerificationResult(
                        spec.DisplayName,
                        false,
                        "AMBIGUOUS - remove the duplicate space/dot filename before verifying.");
                }

                string path = matches[0];
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return new FileVerificationResult(spec.DisplayName, false, "UNSAFE - linked files are not accepted.");
                }

                string actualSha256 = ComputeSha256(path);
                bool passed = string.Equals(actualSha256, spec.ExpectedSha256, StringComparison.OrdinalIgnoreCase);
                return new FileVerificationResult(
                    spec.DisplayName,
                    passed,
                    passed ? "VERIFIED - " + Path.GetFileName(path) : "CHANGED OR CORRUPT - get a clean copy from Justichuu.");
            }
            catch (UnauthorizedAccessException exception)
            {
                return new FileVerificationResult(spec.DisplayName, false, "CANNOT READ - " + exception.Message);
            }
            catch (IOException exception)
            {
                return new FileVerificationResult(spec.DisplayName, false, "READ ERROR - " + exception.Message);
            }
            catch (CryptographicException exception)
            {
                return new FileVerificationResult(spec.DisplayName, false, "HASH ERROR - " + exception.Message);
            }
        }

        private static string ComputeSha256(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 algorithm = SHA256.Create())
            {
                byte[] digest = algorithm.ComputeHash(stream);
                return BitConverter.ToString(digest).Replace("-", string.Empty);
            }
        }
    }

    internal sealed class VerifierForm : Form
    {
        private readonly Label statusLabel;
        private readonly Label distributionLabel;
        private readonly Label sourceLabel;
        private readonly Button verifyButton;
        private readonly Button closeButton;
        private VerificationStatus status;

        internal VerifierForm()
        {
            Text = "Switzerland VPN Release Verifier";
            ClientSize = new Size(680, 365);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(247, 249, 252);
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);

            Label titleLabel = new Label
            {
                AutoSize = false,
                Location = new Point(28, 24),
                Size = new Size(624, 34),
                Font = new Font("Segoe UI Semibold", 18F, FontStyle.Bold, GraphicsUnit.Point),
                Text = "Verify Switzerland VPN v" + EmbeddedReleaseManifest.Version
            };
            Controls.Add(titleLabel);

            Label explanationLabel = new Label
            {
                AutoSize = false,
                Location = new Point(30, 65),
                Size = new Size(620, 40),
                ForeColor = Color.FromArgb(76, 86, 106),
                Text = "Checks both release ZIPs using values built into this app. No internet, sign-in, administrator access, or file changes."
            };
            Controls.Add(explanationLabel);

            statusLabel = new Label
            {
                AutoSize = false,
                Location = new Point(30, 112),
                Size = new Size(620, 52),
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Segoe UI Semibold", 13F, FontStyle.Bold, GraphicsUnit.Point),
                BorderStyle = BorderStyle.FixedSingle
            };
            Controls.Add(statusLabel);

            distributionLabel = CreateResultLabel(180);
            sourceLabel = CreateResultLabel(226);
            Controls.Add(distributionLabel);
            Controls.Add(sourceLabel);

            verifyButton = new Button
            {
                Location = new Point(398, 306),
                Size = new Size(122, 34),
                Text = "Verify Again"
            };
            verifyButton.Click += delegate { BeginVerification(); };
            Controls.Add(verifyButton);

            closeButton = new Button
            {
                Location = new Point(530, 306),
                Size = new Size(120, 34),
                Text = "Close"
            };
            closeButton.Click += delegate { Close(); };
            Controls.Add(closeButton);
            AcceptButton = verifyButton;
            CancelButton = closeButton;

            ApplyStatus(VerificationStatus.Ready, null);
            Shown += delegate { BeginVerification(); };
        }

        private static Label CreateResultLabel(int top)
        {
            return new Label
            {
                AutoSize = false,
                Location = new Point(30, top),
                Size = new Size(620, 38),
                Padding = new Padding(10, 0, 10, 0),
                TextAlign = ContentAlignment.MiddleLeft,
                BackColor = Color.White,
                BorderStyle = BorderStyle.FixedSingle
            };
        }

        private void BeginVerification()
        {
            if (status == VerificationStatus.Verifying)
            {
                return;
            }

            ApplyStatus(VerificationStatus.Verifying, null);
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            Task.Factory.StartNew(delegate { return ReleaseVerifier.Verify(directory); })
                .ContinueWith(CompleteVerification, TaskScheduler.FromCurrentSynchronizationContext());
        }

        private void CompleteVerification(Task<ReleaseVerificationResult> task)
        {
            if (task.IsCanceled)
            {
                ApplyStatus(VerificationStatus.Failed, CreateFailureResult("Verification was canceled."));
                return;
            }
            if (task.IsFaulted)
            {
                Exception failure = task.Exception == null ? null : task.Exception.GetBaseException();
                string message = failure == null ? "Unknown verification error." : failure.Message;
                ApplyStatus(VerificationStatus.Failed, CreateFailureResult(message));
                return;
            }

            ReleaseVerificationResult result = task.Result;
            ApplyStatus(result.Passed ? VerificationStatus.Passed : VerificationStatus.Failed, result);
        }

        private static ReleaseVerificationResult CreateFailureResult(string message)
        {
            return new ReleaseVerificationResult(new[]
            {
                new FileVerificationResult("Distribution ZIP", false, message),
                new FileVerificationResult("Source ZIP", false, message)
            });
        }

        private void ApplyStatus(VerificationStatus newStatus, ReleaseVerificationResult result)
        {
            status = newStatus;
            verifyButton.Enabled = newStatus != VerificationStatus.Verifying;

            if (newStatus == VerificationStatus.Ready)
            {
                statusLabel.Text = "READY TO VERIFY";
                statusLabel.BackColor = Color.FromArgb(231, 238, 248);
                statusLabel.ForeColor = Color.FromArgb(49, 82, 130);
                distributionLabel.Text = "Distribution ZIP - waiting";
                sourceLabel.Text = "Source ZIP - waiting";
                return;
            }
            if (newStatus == VerificationStatus.Verifying)
            {
                statusLabel.Text = "VERIFYING...";
                statusLabel.BackColor = Color.FromArgb(224, 238, 255);
                statusLabel.ForeColor = Color.FromArgb(36, 86, 150);
                distributionLabel.Text = "Distribution ZIP - reading";
                sourceLabel.Text = "Source ZIP - reading";
                return;
            }

            bool passed = newStatus == VerificationStatus.Passed;
            statusLabel.Text = passed ? "PASS - BOTH FILES ARE EXACT" : "FAILED - DO NOT INSTALL THESE FILES";
            statusLabel.BackColor = passed ? Color.FromArgb(218, 242, 225) : Color.FromArgb(255, 224, 224);
            statusLabel.ForeColor = passed ? Color.FromArgb(30, 108, 54) : Color.FromArgb(150, 38, 38);

            if (result == null || result.Files.Length != 2)
            {
                distributionLabel.Text = "Distribution ZIP - result unavailable";
                sourceLabel.Text = "Source ZIP - result unavailable";
                return;
            }
            distributionLabel.Text = result.Files[0].DisplayName + " - " + result.Files[0].Detail;
            sourceLabel.Text = result.Files[1].DisplayName + " - " + result.Files[1].Detail;
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 && string.Equals(args[0], "--quiet", StringComparison.Ordinal))
            {
                try
                {
                    return ReleaseVerifier.Verify(AppDomain.CurrentDomain.BaseDirectory).Passed ? 0 : 1;
                }
                catch
                {
                    return 2;
                }
            }
            if (args.Length != 0)
            {
                return 2;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new VerifierForm());
            return 0;
        }
    }
}
