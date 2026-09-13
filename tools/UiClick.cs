using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Automation;

internal static class UiClick
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
        if (args.Length == 0)
        {
            Console.WriteLine("Usage: UiClick.exe <exact-button-name> --root <install-root>");
            return;
        }

        var buttonName = args[0];
        var targetRoot = GetOption(args, "--root");
        if (string.IsNullOrWhiteSpace(targetRoot))
        {
            Console.WriteLine("Usage: UiClick.exe <exact-button-name> --root <install-root>");
            return;
        }

        var process = GetTargetProcesses(targetRoot).FirstOrDefault();
        if (process == null)
        {
            Console.WriteLine("NO_TARGET_WINDOW");
            return;
        }

        var root = AutomationElement.FromHandle(process.MainWindowHandle);
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.NameProperty, buttonName));
        var matches = root.FindAll(TreeScope.Descendants, condition);
        Console.WriteLine("MATCHES " + matches.Count);
        for (var i = 0; i < matches.Count; i++)
        {
            var element = matches[i];
            try
            {
                object selectionObject;
                if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out selectionObject))
                {
                    var selection = selectionObject as SelectionItemPattern;
                    if (selection != null)
                    {
                        selection.Select();
                        Console.WriteLine("SELECTED name=" + ReadName(element));
                        return;
                    }
                }

                object invokeObject;
                if (!element.TryGetCurrentPattern(InvokePattern.Pattern, out invokeObject))
                {
                    Console.WriteLine("SKIP_NO_INVOKE_PATTERN name=" + ReadName(element));
                    continue;
                }

                var invoke = invokeObject as InvokePattern;
                if (invoke == null)
                {
                    Console.WriteLine("SKIP_NO_INVOKE_PATTERN name=" + ReadName(element));
                    continue;
                }

                invoke.Invoke();
                Console.WriteLine("INVOKED name=" + ReadName(element));
                return;
            }
            catch (Exception ex)
            {
                Console.WriteLine("INVOKE_ERROR " + ex.GetType().Name + ": " + ex.Message);
            }
        }
    }
}
