using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Automation;

internal static class UiProbe
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

    private static string ReadClassName(AutomationElement element)
    {
        try
        {
            return element.Current.ClassName ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
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

    private static void Main(string[] args)
    {
        var targetRoot = GetOption(args, "--root");
        var all = args.Any(a => a.Equals("--all", StringComparison.OrdinalIgnoreCase));
        if (string.IsNullOrWhiteSpace(targetRoot))
        {
            Console.WriteLine("Usage: UiProbe.exe --root <install-root> [--all]");
            return;
        }

        var processes = GetTargetProcesses(targetRoot).ToArray();
        if (processes.Length == 0)
        {
            Console.WriteLine("NO_TARGET_WINDOW");
            return;
        }

        foreach (var process in processes)
        {
            Console.WriteLine("PROCESS pid=" + process.Id + " hwnd=0x" + process.MainWindowHandle.ToString("X"));

            AutomationElement root;
            try
            {
                root = AutomationElement.FromHandle(process.MainWindowHandle);
            }
            catch (Exception ex)
            {
                Console.WriteLine("ROOT_ERROR " + ex.GetType().Name + ": " + ex.Message);
                continue;
            }

            Console.WriteLine("ROOT name=" + ReadName(root) + " type=" + ReadType(root));

            AutomationElementCollection descendants;
            try
            {
                descendants = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
            }
            catch (Exception ex)
            {
                Console.WriteLine("ENUM_ERROR " + ex.GetType().Name + ": " + ex.Message);
                continue;
            }

            Console.WriteLine("DESCENDANTS count=" + descendants.Count);
            var printed = 0;
            for (var i = 0; i < descendants.Count && printed < 3000; i++)
            {
                var element = descendants[i];
                var name = ReadName(element);
                var type = ReadType(element);
                if (all)
                {
                    Console.WriteLine("NODE name=" + name +
                        " type=" + type +
                        " class=" + ReadClassName(element));
                    printed++;
                }
                else if (name.IndexOf("广告", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    name.IndexOf("不感兴趣", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    name.IndexOf("关闭该广告", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    type.IndexOf("ListItem", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    Console.WriteLine("NODE name=" + name + " type=" + type);
                    printed++;
                }
            }

            Console.WriteLine("MATCHED_NODES count=" + printed);
        }
    }
}
