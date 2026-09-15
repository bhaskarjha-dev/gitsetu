using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace GitSetuLauncher {
    class Program {
        static int Main(string[] args) {
            string bash = FindBash();
            if (string.IsNullOrEmpty(bash)) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.Error.WriteLine("[Error] Git for Windows (bash.exe) was not found.");
                Console.ResetColor();
                Console.Error.WriteLine("GitSetu requires Git for Windows. Please install Git:");
                Console.Error.WriteLine("  - Download: https://git-scm.com/download/win");
                Console.Error.WriteLine("  - Or run: winget install Git.Git");
                return 1;
            }

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(baseDir, "gitsetu");
            if (!File.Exists(script)) {
                // Fallback to local appdata install location
                string localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string candidate = Path.Combine(localApp, "gitsetu", "share", "gitsetu");
                if (File.Exists(candidate)) {
                    script = candidate;
                }
            }

            if (!File.Exists(script)) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.Error.WriteLine("[Error] GitSetu core script not found.");
                Console.ResetColor();
                Console.Error.WriteLine("Expected script at: " + script);
                Console.Error.WriteLine("Please reinstall GitSetu: winget install BhaskarJha.GitSetu");
                return 1;
            }

            StringBuilder sb = new StringBuilder();
            sb.Append("\"").Append(script.Replace('\\', '/')).Append("\"");
            for (int i = 0; i < args.Length; i++) {
                sb.Append(" ");
                string a = args[i];
                if (a.Contains(" ") || a.Contains("\"") || a.Length == 0) {
                    sb.Append("\"").Append(a.Replace("\"", "\\\"")).Append("\"");
                } else {
                    sb.Append(a);
                }
            }

            ProcessStartInfo psi = new ProcessStartInfo {
                FileName = bash,
                Arguments = sb.ToString(),
                UseShellExecute = false
            };

            try {
                using (Process proc = Process.Start(psi)) {
                    proc.WaitForExit();
                    return proc.ExitCode;
                }
            } catch (Exception ex) {
                Console.Error.WriteLine("[Error] Failed to launch GitSetu: " + ex.Message);
                return 1;
            }
        }

        static string FindBash() {
            string custom = Environment.GetEnvironmentVariable("GITSETU_BASH");
            if (!string.IsNullOrEmpty(custom) && File.Exists(custom)) return custom;

            string[] whereLines = null;
            try {
                ProcessStartInfo wpsi = new ProcessStartInfo {
                    FileName = "where.exe",
                    Arguments = "bash.exe",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };
                using (Process wp = Process.Start(wpsi)) {
                    string output = wp.StandardOutput.ReadToEnd();
                    wp.WaitForExit();
                    if (wp.ExitCode == 0) {
                        whereLines = output.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                        for (int i = 0; i < whereLines.Length; i++) {
                            string trimmed = whereLines[i].Trim();
                            if (trimmed.IndexOf("git", StringComparison.OrdinalIgnoreCase) >= 0 && File.Exists(trimmed)) {
                                return trimmed;
                            }
                        }
                    }
                }
            } catch {}

            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string p1 = Path.Combine(pf, "Git", "bin", "bash.exe");
            if (File.Exists(p1)) return p1;

            string pfx86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            string p2 = Path.Combine(pfx86, "Git", "bin", "bash.exe");
            if (File.Exists(p2)) return p2;

            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string p3 = Path.Combine(local, "Programs", "Git", "bin", "bash.exe");
            if (File.Exists(p3)) return p3;

            // Fallback: any non-System32/SysWOW64 bash found by where.exe
            if (whereLines != null) {
                for (int i = 0; i < whereLines.Length; i++) {
                    string trimmed = whereLines[i].Trim();
                    if (trimmed.IndexOf("system32", StringComparison.OrdinalIgnoreCase) < 0 &&
                        trimmed.IndexOf("syswow64", StringComparison.OrdinalIgnoreCase) < 0 &&
                        File.Exists(trimmed)) {
                        return trimmed;
                    }
                }
            }

            return null;
        }
    }
}
