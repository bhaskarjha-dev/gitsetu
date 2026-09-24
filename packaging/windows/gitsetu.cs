using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace GitSetuLauncher {
    internal static class Program {
        private static readonly SecurityIdentifier SystemSid = new SecurityIdentifier("S-1-5-18");
        private static readonly SecurityIdentifier AdministratorsSid = new SecurityIdentifier("S-1-5-32-544");
        private static readonly SecurityIdentifier TrustedInstallerSid = new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

        private static int Main(string[] args) {
            if (args.Length == 1 && args[0] == "--argv-self-test") {
                return RunArgumentQuotingSelfTest();
            }

            string bash;
            try {
                bash = FindTrustedGitBash();
            } catch (Exception ex) {
                Console.Error.WriteLine("[Error] Git for Windows trust validation failed: " + ex.Message);
                return 1;
            }
            if (String.IsNullOrEmpty(bash)) {
                Console.Error.WriteLine("[Error] Git for Windows was not found in a trusted standard installation root.");
                Console.Error.WriteLine("Install the official Git for Windows package, then retry.");
                return 1;
            }

            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.GetFullPath(Path.Combine(baseDirectory, "gitsetu"));
            try {
                ValidateRegularFile(script, "GitSetu core script", IsTestMode(), GetAllowedScoopCurrent(baseDirectory));
            } catch (Exception ex) {
                Console.Error.WriteLine("[Error] GitSetu core script is unavailable or untrusted: " + ex.Message);
                return 1;
            }

            StringBuilder commandLine = new StringBuilder();
            AppendQuotedArgument(commandLine, script.Replace('\\', '/'), true);
            foreach (string argument in args) {
                commandLine.Append(' ');
                AppendQuotedArgument(commandLine, argument);
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = bash;
            startInfo.Arguments = commandLine.ToString();
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            bool pumpOutput = Console.IsOutputRedirected || Console.IsErrorRedirected;
            startInfo.RedirectStandardOutput = pumpOutput;
            startInfo.RedirectStandardError = pumpOutput;
            try {
                using (Process process = Process.Start(startInfo)) {
                    if (process == null) {
                        Console.Error.WriteLine("[Error] Failed to start Git for Windows Bash.");
                        return 1;
                    }
                    if (pumpOutput) {
                        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs) {
                            if (eventArgs.Data != null) Console.Out.WriteLine(eventArgs.Data);
                        };
                        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs) {
                            if (eventArgs.Data != null) Console.Error.WriteLine(eventArgs.Data);
                        };
                        process.BeginOutputReadLine();
                        process.BeginErrorReadLine();
                    }
                    process.WaitForExit();
                    return process.ExitCode;
                }
            } catch (Exception ex) {
                Console.Error.WriteLine("[Error] Failed to launch GitSetu: " + ex.Message);
                return 1;
            }
        }

        private static bool IsTestMode() {
#if GITSETU_TEST_MODE
            return String.Equals(Environment.GetEnvironmentVariable("GITSETU_TEST_MODE"), "1", StringComparison.Ordinal);
#else
            return false;
#endif
        }

        private static string FindTrustedGitBash() {
            if (IsTestMode()) {
                string testOverride = Environment.GetEnvironmentVariable("GITSETU_TEST_GIT_BASH");
                if (!String.IsNullOrWhiteSpace(testOverride)) {
                    string fullTestPath = Path.GetFullPath(testOverride);
                    if (!Path.IsPathRooted(fullTestPath) || !String.Equals(Path.GetFileName(fullTestPath), "bash.exe", StringComparison.OrdinalIgnoreCase)) {
                        throw new InvalidOperationException("Test Git Bash override must be an absolute bash.exe path.");
                    }
                    ValidateRegularFile(fullTestPath, "test Git Bash", true, null);
                    return fullTestPath;
                }
            }

            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string[] roots = new string[] {
                Path.Combine(programFiles, "Git"),
                Path.Combine(programFilesX86, "Git"),
                Path.Combine(localAppData, "Programs", "Git")
            };
            string[] relatives = new string[] {
                Path.Combine("bin", "bash.exe"),
                Path.Combine("usr", "bin", "bash.exe")
            };

            foreach (string root in roots) {
                if (String.IsNullOrWhiteSpace(root)) continue;
                foreach (string relative in relatives) {
                    string candidate = Path.GetFullPath(Path.Combine(root, relative));
                    string rootPrefix = Path.GetFullPath(root).TrimEnd('\\') + "\\";
                    if (!candidate.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase)) continue;
                    if (!File.Exists(candidate)) continue;
                    try {
                        ValidateRegularFile(candidate, "Git for Windows Bash", false, null);
                        return candidate;
                    } catch (UnauthorizedAccessException) {
                        // An inaccessible/untrusted candidate is never promoted.
                    } catch (System.Security.SecurityException) {
                        // An inaccessible/untrusted candidate is never promoted.
                    }
                }
            }
            return null;
        }

        private static string GetAllowedScoopCurrent(string baseDirectory) {
            try {
                DirectoryInfo current = new DirectoryInfo(baseDirectory);
                if (!String.Equals(current.Name, "current", StringComparison.OrdinalIgnoreCase)) return null;
                if ((current.Attributes & FileAttributes.ReparsePoint) == 0) return null;
                DirectoryInfo app = current.Parent;
                DirectoryInfo apps = app == null ? null : app.Parent;
                if (app == null || apps == null || !String.Equals(apps.Name, "apps", StringComparison.OrdinalIgnoreCase)) return null;
                return current.FullName;
            } catch {
                return null;
            }
        }

        private static string GetFinalPath(string path) {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                StringBuilder buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(stream.SafeFileHandle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity) throw new IOException("Could not resolve final Windows path.");
                string final = buffer.ToString();
                if (final.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) final = @"\\" + final.Substring(8);
                else if (final.StartsWith(@"\\?\", StringComparison.Ordinal)) final = final.Substring(4);
                return Path.GetFullPath(final);
            }
        }

        private static void ValidateRegularFile(string path, string label, bool testOwnedFile, string allowedReparseComponent) {
            if (!Path.IsPathRooted(path)) throw new InvalidOperationException(label + " path is not absolute.");
            string fullPath = Path.GetFullPath(path);
            FileAttributes attributes = File.GetAttributes(fullPath);
            if ((attributes & FileAttributes.Directory) != 0 || (attributes & FileAttributes.ReparsePoint) != 0) {
                throw new InvalidOperationException(label + " is not a regular, non-reparse file.");
            }

            string root = Path.GetPathRoot(fullPath);
            bool allowedReparseUsed = false;
            DirectoryInfo current = new DirectoryInfo(Path.GetDirectoryName(fullPath));
            while (current != null && !String.Equals(current.FullName.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0) {
                    if (allowedReparseComponent != null && String.Equals(current.FullName.TrimEnd('\\'), allowedReparseComponent.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) {
                        allowedReparseUsed = true;
                    } else {
                        throw new InvalidOperationException(label + " has a reparse-point path component: " + current.FullName);
                    }
                }
                current = current.Parent;
            }
            if (allowedReparseComponent != null) {
                if (!allowedReparseUsed) throw new InvalidOperationException("Expected package-manager reparse point was not present.");
                string appRoot = Path.GetDirectoryName(allowedReparseComponent.TrimEnd('\\')).TrimEnd('\\');
                string finalPath = GetFinalPath(fullPath);
                string versionDirectory = Path.GetDirectoryName(finalPath);
                string versionName = Path.GetFileName(versionDirectory);
                if (!finalPath.StartsWith(appRoot + "\\", StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(Path.GetDirectoryName(versionDirectory).TrimEnd('\\'), appRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ||
                    versionName.Length == 0 || !Char.IsDigit(versionName[0]) || versionName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) {
                    throw new InvalidOperationException("Scoop current junction escapes the versioned package directory.");
                }
            }

            if (testOwnedFile) return;

            FileSecurity security = File.GetAccessControl(fullPath, AccessControlSections.Access | AccessControlSections.Owner);
            SecurityIdentifier owner = (SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier));
            SecurityIdentifier currentUser = WindowsIdentity.GetCurrent().User;
            if (!IsTrustedSid(owner) && !owner.Equals(currentUser)) {
                throw new UnauthorizedAccessException("Untrusted owner " + owner.Value + " on " + label + ".");
            }

            AuthorizationRuleCollection rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules) {
                FileSystemRights rights = rule.FileSystemRights;
                FileSystemRights dangerous = FileSystemRights.WriteData | FileSystemRights.AppendData |
                    FileSystemRights.WriteAttributes | FileSystemRights.WriteExtendedAttributes |
                    FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
                if (rule.AccessControlType == AccessControlType.Allow && (rights & dangerous) != 0) {
                    SecurityIdentifier sid = (SecurityIdentifier)rule.IdentityReference;
                    if (!IsTrustedSid(sid) && !sid.Equals(currentUser)) {
                        throw new UnauthorizedAccessException("Untrusted write ACL " + sid.Value + " on " + label + ".");
                    }
                }
            }
        }

        private static bool IsTrustedSid(SecurityIdentifier sid) {
            return sid.Equals(SystemSid) || sid.Equals(AdministratorsSid) || sid.Equals(TrustedInstallerSid);
        }

        // Quotes one argument using the inverse of the CommandLineToArgvW/MSVC
        // parsing rules. In particular, runs of backslashes are doubled before
        // a quote and at the end of a quoted argument.
        private static void AppendQuotedArgument(StringBuilder output, string argument) {
            AppendQuotedArgument(output, argument, false);
        }

        private static void AppendQuotedArgument(StringBuilder output, string argument, bool forceQuotes) {
            if (argument == null) argument = String.Empty;
            bool needsQuotes = forceQuotes || argument.Length == 0;
            for (int i = 0; i < argument.Length && !needsQuotes; i++) {
                needsQuotes = Char.IsWhiteSpace(argument[i]) || argument[i] == '"';
            }
            if (!needsQuotes) {
                output.Append(argument);
                return;
            }

            output.Append('"');
            int backslashes = 0;
            foreach (char character in argument) {
                if (character == '\\') {
                    backslashes++;
                    continue;
                }
                if (character == '"') {
                    output.Append('\\', (backslashes * 2) + 1);
                    output.Append('"');
                    backslashes = 0;
                    continue;
                }
                output.Append('\\', backslashes);
                backslashes = 0;
                output.Append(character);
            }
            output.Append('\\', backslashes * 2);
            output.Append('"');
        }

        private static int RunArgumentQuotingSelfTest() {
            string[,] fixtures = new string[,] {
                { "simple", "simple" },
                { "two words", "\"two words\"" },
                { "", "\"\"" },
                { "ends with space\\", "\"ends with space\\\\\"" },
                { "a\\\"b", "\"a\\\\\\\"b\"" },
                { "tab\tvalue", "\"tab\tvalue\"" },
                { "line\nvalue", "\"line\nvalue\"" }
            };
            for (int i = 0; i < fixtures.GetLength(0); i++) {
                StringBuilder actual = new StringBuilder();
                AppendQuotedArgument(actual, fixtures[i, 0]);
                if (!String.Equals(actual.ToString(), fixtures[i, 1], StringComparison.Ordinal)) {
                    Console.Error.WriteLine("argv quoting self-test failed at fixture " + i + ": " + actual);
                    return 1;
                }
            }
            Console.WriteLine("argv quoting self-test passed");
            return 0;
        }
    }
}
