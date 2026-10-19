# Captures Win+P when Windows still owns the project shortcut, then shows or hides Flow Launcher.
# Win+Shift+P opens Flow Launcher on the open-window search.
$ErrorActionPreference = "Stop"

$mutex = New-Object System.Threading.Mutex($false, "Local\WindowsSetupFlowLauncherHotkey")
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}

if (-not $owned) {
    return
}

if (-not ([System.Management.Automation.PSTypeName]"WindowsSetup.FlowHotkeyHook").Type) {
    Add-Type -ReferencedAssemblies @("UIAutomationClient", "UIAutomationTypes") -TypeDefinition @"
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace WindowsSetup {
    public static class FlowHotkeyHook {
        private const int WhKeyboardLl = 13;
        private const int WmKeyDown = 0x0100;
        private const int WmSysKeyDown = 0x0104;
        private const int VkEscape = 0x1B;
        private const int VkP = 0x50;
        private const int VkLWin = 0x5B;
        private const int VkRWin = 0x5C;
        private const int VkControl = 0x11;
        private const int VkMenu = 0x12;
        private const int VkShift = 0x10;
        private const int KeyeventfKeyup = 0x0002;
        private const int LlkfInjected = 0x10;

        private const string WindowQuery = "w ";

        private static IntPtr hook;
        private static HookProc proc;
        private static int lastToggle;
        private static int lastWindowSearch;

        private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll")]
        private static extern bool UnhookWindowsHookEx(IntPtr hookHandle);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hookHandle, int code, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out MSG message, IntPtr window, uint min, uint max);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int key);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

        public static void Run() {
            proc = Callback;
            hook = SetWindowsHookEx(WhKeyboardLl, proc, GetModuleHandle(null), 0);
            MSG message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
            }
            if (hook != IntPtr.Zero) {
                UnhookWindowsHookEx(hook);
            }
        }

        private static bool IsDown(int key) {
            return (GetAsyncKeyState(key) & 0x8000) != 0;
        }

        private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
            try {
                int message = wParam.ToInt32();
                if (code >= 0 && (message == WmKeyDown || message == WmSysKeyDown)) {
                    KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    bool injected = (data.flags & (uint)LlkfInjected) != 0;
                    bool win = IsDown(VkLWin) || IsDown(VkRWin);
                    bool ctrl = IsDown(VkControl);
                    bool alt = IsDown(VkMenu);
                    bool shift = IsDown(VkShift);
                    if (!injected && data.vkCode == (uint)VkP && win && !ctrl && !alt) {
                        if (shift) {
                            SearchWindows();
                        } else {
                            Toggle();
                        }
                        return (IntPtr)1;
                    }
                }
            } catch {
            }

            return CallNextHookEx(hook, code, wParam, lParam);
        }

        private static void Toggle() {
            int now = Environment.TickCount;
            int elapsed = unchecked(now - lastToggle);
            if (lastToggle != 0 && elapsed >= 0 && elapsed < 400) {
                return;
            }
            lastToggle = now;

            if (IsFlowForeground()) {
                keybd_event(VkEscape, 0, 0, UIntPtr.Zero);
                keybd_event(VkEscape, 0, KeyeventfKeyup, UIntPtr.Zero);
                return;
            }

            string executable = ResolveExecutable();
            if (executable == null) {
                return;
            }

            if (Process.GetProcessesByName("Flow.Launcher").Length == 0) {
                Process.Start(executable);
                ThreadPool.QueueUserWorkItem(delegate(object state) {
                    try {
                        for (int attempt = 0; attempt < 30; attempt++) {
                            Thread.Sleep(100);
                            if (Process.GetProcessesByName("Flow.Launcher").Length > 0) {
                                break;
                            }
                        }
                        Process.Start(executable);
                    } catch {
                    }
                });
                return;
            }

            Process.Start(executable);
        }

        private static void SearchWindows() {
            int now = Environment.TickCount;
            int elapsed = unchecked(now - lastWindowSearch);
            if (lastWindowSearch != 0 && elapsed >= 0 && elapsed < 400) {
                return;
            }
            lastWindowSearch = now;

            string executable = ResolveExecutable();
            if (executable == null) {
                return;
            }

            if (Process.GetProcessesByName("Flow.Launcher").Length == 0) {
                Process.Start(executable);
                ThreadPool.QueueUserWorkItem(delegate(object state) {
                    try {
                        for (int attempt = 0; attempt < 30; attempt++) {
                            Thread.Sleep(100);
                            if (Process.GetProcessesByName("Flow.Launcher").Length > 0) {
                                break;
                            }
                        }
                        Process.Start(executable);
                        SetWindowQuery();
                    } catch {
                    }
                });
                return;
            }

            if (!IsFlowWindowVisible()) {
                Process.Start(executable);
            }

            ThreadPool.QueueUserWorkItem(delegate(object state) {
                try {
                    SetWindowQuery();
                } catch {
                }
            });
        }

        private static bool IsFlowWindowVisible() {
            AutomationElement window = AutomationElement.RootElement.FindFirst(
                TreeScope.Children,
                new PropertyCondition(AutomationElement.AutomationIdProperty, "FlowMainWindow"));
            return window != null;
        }

        private static void SetWindowQuery() {
            for (int attempt = 0; attempt < 30; attempt++) {
                AutomationElement window = AutomationElement.RootElement.FindFirst(
                    TreeScope.Children,
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "FlowMainWindow"));
                if (window != null) {
                    AutomationElement box = window.FindFirst(
                        TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.AutomationIdProperty, "QueryTextBox"));
                    if (box != null) {
                        object pattern;
                        if (box.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) {
                            ((ValuePattern)pattern).SetValue(WindowQuery);
                            MoveCaretToEnd(box);
                            return;
                        }
                    }
                }
                Thread.Sleep(100);
            }
        }

        private static void MoveCaretToEnd(AutomationElement box) {
            object pattern;
            if (!box.TryGetCurrentPattern(TextPattern.Pattern, out pattern)) {
                return;
            }

            TextPattern text = (TextPattern)pattern;
            TextPatternRange end = text.DocumentRange;
            end.MoveEndpointByRange(TextPatternRangeEndpoint.Start, end, TextPatternRangeEndpoint.End);
            end.Select();
            box.SetFocus();
        }

        private static bool IsFlowForeground() {
            IntPtr foreground = GetForegroundWindow();
            uint foregroundProcessId;
            GetWindowThreadProcessId(foreground, out foregroundProcessId);
            Process[] processes = Process.GetProcessesByName("Flow.Launcher");
            for (int index = 0; index < processes.Length; index++) {
                if ((uint)processes[index].Id == foregroundProcessId) {
                    return true;
                }
            }
            return false;
        }

        private static string ResolveExecutable() {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FlowLauncher");
            string stub = Path.Combine(root, "Flow.Launcher.exe");
            if (File.Exists(stub)) {
                return stub;
            }
            if (!Directory.Exists(root)) {
                return null;
            }
            string[] matches = Directory.GetFiles(root, "Flow.Launcher.exe", SearchOption.AllDirectories);
            if (matches.Length == 0) {
                return null;
            }
            return matches[0];
        }
    }
}
"@
}

[WindowsSetup.FlowHotkeyHook]::Run()
$mutex.Dispose()
