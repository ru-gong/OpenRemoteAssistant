// SPDX-License-Identifier: GPL-3.0-only
// Entry point: GUI (default) or headless CLI self-checks (--device-check etc.).

namespace OpenRemoteAssistant.Win;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            InstallCrashLogger();
            ApplicationConfiguration.Initialize();
            Application.Run(new MainForm());
            return 0;
        }
        return Headless.Run(args);
    }

    /// <summary>Writes unhandled exceptions to %LOCALAPPDATA%\OpenRemoteAssistant\crash.log</summary>
    private static void InstallCrashLogger()
    {
        void Write(string source, Exception ex)
        {
            try
            {
                var dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenRemoteAssistant");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "crash.log"),
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}: {ex}\n---\n");
            }
            catch { }
        }
        Application.ThreadException += (s, e) => Write("UI", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            Write("domain", e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject.ToString() ?? "unknown"));
        TaskScheduler.UnobservedTaskException += (s, e) => { Write("task", e.Exception); e.SetObserved(); };
    }
}
