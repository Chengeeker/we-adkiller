using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Automation;

internal static class AdCleaner
{
    private static string ReadName(AutomationElement element)
    {
        try
        {
            return element.Current.Name ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string ReadType(AutomationElement element)
    {
        try
        {
            var controlType = element.Current.ControlType;
            return controlType == null ? string.Empty : controlType.ProgrammaticName;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static bool IsCloseButton(AutomationElement element)
    {
        var name = ReadName(element);
        var type = ReadType(element);
        return type.IndexOf("Button", StringComparison.OrdinalIgnoreCase) >= 0 &&
            (name.Equals("关闭该广告", StringComparison.OrdinalIgnoreCase) ||
             name.Equals("关闭广告", StringComparison.OrdinalIgnoreCase));
    }

    private static IEnumerable<Process> GetTargetProcesses(string targetRoot)
    {
        var normalizedRoot = Path.GetFullPath(targetRoot)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
            Path.DirectorySeparatorChar;
        var matches = new List<Process>();

        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.MainWindowHandle == IntPtr.Zero)
                {
                    continue;
                }

                var module = process.MainModule;
                var executablePath = module == null ? string.Empty : module.FileName;
                if (!string.IsNullOrEmpty(executablePath) &&
                    executablePath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                {
                    matches.Add(process);
                }
            }
            catch
            {
                // Some system processes deny module inspection.
            }
        }
        return matches;
    }

    private static string GetOption(string[] args, string name)
    {
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i].Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }
        return string.Empty;
    }

    private static void Sweep(string targetRoot, bool apply)
    {
        var processes = GetTargetProcesses(targetRoot).ToArray();
        var seen = 0;
        var applied = 0;

        foreach (var process in processes)
        {
            AutomationElement root;
            try
            {
                root = AutomationElement.FromHandle(process.MainWindowHandle);
            }
            catch (Exception ex)
            {
                Console.WriteLine("ROOT_ERROR pid=" + process.Id + " " + ex.GetType().Name + ": " + ex.Message);
                continue;
            }

            AutomationElementCollection nodes;
            try
            {
                nodes = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
            }
            catch (Exception ex)
            {
                Console.WriteLine("ENUM_ERROR pid=" + process.Id + " " + ex.GetType().Name + ": " + ex.Message);
                continue;
            }

            for (var i = 0; i < nodes.Count; i++)
            {
                var element = nodes[i];
                if (!IsCloseButton(element))
                {
                    continue;
                }

                seen++;
                Console.WriteLine((apply ? "APPLY" : "DRY_RUN") +
                    " pid=" + process.Id + " name=" + ReadName(element));

                if (!apply)
                {
                    continue;
                }

                try
                {
                    object patternObject;
                    if (!element.TryGetCurrentPattern(InvokePattern.Pattern, out patternObject))
                    {
                        Console.WriteLine("SKIP_NO_INVOKE_PATTERN");
                        continue;
                    }

                    var invoke = patternObject as InvokePattern;
                    if (invoke == null)
                    {
                        Console.WriteLine("SKIP_NO_INVOKE_PATTERN");
                        continue;
                    }

                    invoke.Invoke();
                    applied++;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("APPLY_ERROR " + ex.GetType().Name + ": " + ex.Message);
                }
            }
        }

        Console.WriteLine("SUMMARY visible_close_buttons=" + seen + " applied=" + applied);
    }

    private static void Main(string[] args)
    {
        var targetRoot = GetOption(args, "--root");
        var apply = args.Any(a => a.Equals("--apply", StringComparison.OrdinalIgnoreCase));
        var watch = args.Any(a => a.Equals("--watch", StringComparison.OrdinalIgnoreCase));

        if (string.IsNullOrWhiteSpace(targetRoot))
        {
            Console.WriteLine("Usage: AdCleaner.exe --root <install-root> [--apply] [--watch]");
            return;
        }

        if (!watch)
        {
            Sweep(targetRoot, apply);
            return;
        }

        Console.WriteLine("WATCHING; press Ctrl+C to stop. Only visible close-ad buttons are invoked.");
        while (true)
        {
            Sweep(targetRoot, apply);
            Thread.Sleep(800);
        }
    }
}
