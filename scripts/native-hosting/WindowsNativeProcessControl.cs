using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public enum NativeProcessLiveness { Alive, Dead, Error }
public enum NativeStartFailureDisposition { NoProcessCleanup, Cleaned, RetainOwnedError }

public sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public SafeKernelHandle() : base(true) { }
    public SafeKernelHandle(IntPtr value) : base(true) { SetHandle(value); }
    protected override bool ReleaseHandle() { return WindowsNativeProcessControl.CloseHandle(handle); }
}

public sealed class WindowsNativeProcessLease : IDisposable
{
    readonly SafeKernelHandle process, job;
    public readonly uint Pid;
    public readonly string CreationToken;
    internal WindowsNativeProcessLease(SafeKernelHandle processHandle, SafeKernelHandle jobHandle, uint pid, string token) { process = processHandle; job = jobHandle; Pid = pid; CreationToken = token; }
    public NativeProcessLiveness Liveness { get { return WindowsNativeProcessControl.GetLiveness(process); } }
    public bool IsAlive { get { return Liveness == NativeProcessLiveness.Alive; } }
    public bool SendCtrlC() { return IsAlive && WindowsNativeProcessControl.SendCtrlC(); }
    public bool ForceTerminate() { return IsAlive && WindowsNativeProcessControl.TerminateProcess(process, 1); }
    public bool Wait(int milliseconds) { return WindowsNativeProcessControl.Wait(process, milliseconds); }
    public uint ExitCode { get { if (Liveness != NativeProcessLiveness.Dead) throw new InvalidOperationException("exit code is valid only after process death"); uint code; if (!WindowsNativeProcessControl.GetExitCodeProcess(process, out code)) throw new Win32Exception(); return code; } }
    public void Dispose() { if (Liveness != NativeProcessLiveness.Dead) throw new InvalidOperationException("process handle cannot be disposed while the owned child is alive or unknown"); process.Dispose(); job.Dispose(); }
}

public static class WindowsNativeProcessControl
{
    const uint CREATE_SUSPENDED = 0x00000004, CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint STARTF_USESHOWWINDOW = 0x00000001, STARTF_USESTDHANDLES = 0x00000100, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;
    const uint CTRL_C_EVENT = 0, STILL_ACTIVE = 259, SW_HIDE = 0, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258, WAIT_FAILED = 0xffffffff;
    static readonly ConsoleCtrlHandler IgnoreCtrlC = IgnoreConsoleControl;
    static SafeKernelHandle retainedProcess, retainedJob;
    public static bool DedicatedConsoleReady { get; private set; }
    delegate bool ConsoleCtrlHandler(uint signal);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars; public int dwFillAttribute; public uint dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] struct JOB_LIMITS { public BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int Length; public IntPtr Descriptor; public int Inherit; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeKernelHandle CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(SafeKernelHandle job, uint type, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(SafeKernelHandle job, SafeKernelHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeKernelHandle CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(SafeKernelHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetExitCodeProcess(SafeKernelHandle process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(SafeKernelHandle process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeKernelHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(SafeKernelHandle handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GenerateConsoleCtrlEvent(uint signal, uint group);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateProcess(SafeKernelHandle process, uint code);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFinalPathNameByHandle(SafeKernelHandle handle, StringBuilder path, uint length, uint flags);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(SafeKernelHandle process, int informationClass, IntPtr information, int length, out int returnLength);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [StructLayout(LayoutKind.Sequential)] struct UNICODE_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PROCESSENTRY32 { public uint Size, Usage, Pid; public IntPtr DefaultHeap; public uint ModuleId, Threads, ParentPid; public int BasePriority; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

    static bool IgnoreConsoleControl(uint signal) { return true; }
    public static bool CanSendCtrlC(bool dedicatedConsole, bool childAlive) { return dedicatedConsole && childAlive; }
    public static NativeStartFailureDisposition StartFailureDisposition(bool processCreated, bool confirmedDead, bool waitErrored) { if (!processCreated) return NativeStartFailureDisposition.NoProcessCleanup; return confirmedDead && !waitErrored ? NativeStartFailureDisposition.Cleaned : NativeStartFailureDisposition.RetainOwnedError; }
    public static bool HasRetainedFailedProcess { get { return retainedProcess != null && !retainedProcess.IsInvalid; } }
    public static bool CleanupRetainedFailure()
    {
        if (!HasRetainedFailedProcess) return true;
        if (GetLiveness(retainedProcess) == NativeProcessLiveness.Alive) TerminateProcess(retainedProcess, 1);
        if (!Wait(retainedProcess, 1000)) return false;
        retainedProcess.Dispose(); retainedProcess = null;
        if (retainedJob != null) { retainedJob.Dispose(); retainedJob = null; }
        return true;
    }
    public static string ResolveFinalPath(string directory)
    {
        try {
            var security = new SECURITY_ATTRIBUTES { Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), Inherit = 0 };
            using (var handle = CreateFile(directory, 0, 7, ref security, 3, 0x02000000, IntPtr.Zero)) {
                if (handle == null || handle.IsInvalid) return "";
                var path = new StringBuilder(32768); uint length = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
                if (length == 0 || length >= path.Capacity) return "";
                var result = path.ToString();
                if (result.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) return "\\\\" + result.Substring(8);
                return result.StartsWith("\\\\?\\", StringComparison.Ordinal) ? result.Substring(4) : result;
            }
        } catch { return ""; }
    }
    public static string NormalizeCreationTime(string timestamp) { return long.Parse(timestamp, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture); }
    public static NativeProcessLiveness GetLiveness(SafeKernelHandle process)
    {
        if (process == null || process.IsInvalid || process.IsClosed) return NativeProcessLiveness.Error;
        uint wait = WaitForSingleObject(process, 0);
        if (wait == WAIT_OBJECT_0) return NativeProcessLiveness.Dead;
        if (wait == WAIT_TIMEOUT) return NativeProcessLiveness.Alive;
        return NativeProcessLiveness.Error;
    }
    public static NativeProcessLiveness LivenessForPid(uint pid)
    {
        if (pid <= 1) return NativeProcessLiveness.Error;
        using (var process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | 0x00100000, false, pid))
        {
            if (process == null || process.IsInvalid) return Marshal.GetLastWin32Error() == 87 ? NativeProcessLiveness.Dead : NativeProcessLiveness.Error;
            return GetLiveness(process);
        }
    }
    public static bool Wait(SafeKernelHandle process, int milliseconds) { return process != null && WaitForSingleObject(process, (uint)Math.Max(0, milliseconds)) == WAIT_OBJECT_0; }
    public static void PrepareDedicatedConsole() { FreeConsole(); if (!AllocConsole()) throw new Win32Exception(); try { var window = GetConsoleWindow(); if (window != IntPtr.Zero) ShowWindow(window, (int)SW_HIDE); if (!SetConsoleCtrlHandler(IgnoreCtrlC, true)) throw new Win32Exception(); DedicatedConsoleReady = true; } catch { FreeConsole(); throw; } }
    public static void ReleaseDedicatedConsole() { if (!DedicatedConsoleReady) return; SetConsoleCtrlHandler(IgnoreCtrlC, false); FreeConsole(); DedicatedConsoleReady = false; }
    public static string Quote(string value)
    {
        if (value == null || value.IndexOfAny(new[] { '\r', '\n', '\0' }) >= 0) throw new ArgumentException("unsafe process argument");
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) { if (c == '\\') { slashes++; continue; } if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append('"'); } else { b.Append('\\', slashes); b.Append(c); } slashes = 0; }
        b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
    }
    public static string CommandLine(string exe, string[] args) { var b = new StringBuilder(Quote(exe)); foreach (var arg in args) b.Append(' ').Append(Quote(arg)); return b.ToString(); }
    public static WindowsNativeProcessLease Start(string runtime, string[] args, string workingDirectory, string logPath)
    {
        if (!DedicatedConsoleReady) throw new InvalidOperationException("dedicated console is not ready");
        var security = new SECURITY_ATTRIBUTES { Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), Inherit = 1 }; var log = CreateFile(logPath, 0x40000000, 3, ref security, 4, 0x80, IntPtr.Zero); if (log.IsInvalid) throw new Win32Exception();
        var input = CreateFile("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero);
        if (input.IsInvalid) { log.Dispose(); input.Dispose(); throw new Win32Exception(); }
        var si = new STARTUPINFO { cb = Marshal.SizeOf(typeof(STARTUPINFO)), dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES, wShowWindow = 0, hStdInput = input.DangerousGetHandle(), hStdOutput = log.DangerousGetHandle(), hStdError = log.DangerousGetHandle() }; PROCESS_INFORMATION pi;
        if (!CreateProcess(runtime, new StringBuilder(CommandLine(runtime, args)), IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, workingDirectory, ref si, out pi)) { log.Dispose(); input.Dispose(); throw new Win32Exception(); }
        log.Dispose(); input.Dispose(); SafeKernelHandle job = null;
        var process = new SafeKernelHandle(pi.hProcess);
        var thread = new SafeKernelHandle(pi.hThread);
        try {
            job = CreateJobObject(IntPtr.Zero, null); if (job == null || job.IsInvalid) throw new Win32Exception();
            var limits = new JOB_LIMITS { Basic = new BASIC_LIMIT_INFORMATION { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE } }; var memory = Marshal.AllocHGlobal(Marshal.SizeOf(limits));
            try { Marshal.StructureToPtr(limits, memory, false); if (!SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, memory, (uint)Marshal.SizeOf(limits)) || !AssignProcessToJobObject(job, process) || ResumeThread(thread) == 0xffffffff) throw new Win32Exception(); } finally { Marshal.FreeHGlobal(memory); }
            thread.Dispose(); long created, exited, kernel, user; if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) throw new Win32Exception();
            return new WindowsNativeProcessLease(process, job, pi.dwProcessId, created.ToString(CultureInfo.InvariantCulture));
        } catch {
            // The process is still suspended until assignment/resume succeeds; use its owned handle and wait before closing it.
            if (!process.IsInvalid) {
                TerminateProcess(process, 1); uint wait = WaitForSingleObject(process, 5000); bool dead = wait == WAIT_OBJECT_0; if (StartFailureDisposition(true, dead, wait == WAIT_FAILED) == NativeStartFailureDisposition.Cleaned) process.Dispose(); else retainedProcess = process;
            }
            thread.Dispose();
            if (job != null) { if (retainedProcess != null) retainedJob = job; else job.Dispose(); }
            throw;
        }
    }
    public static string CreationTokenForPid(uint pid) { using (var process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)) { if (process.IsInvalid) throw new Win32Exception(); long created, exited, kernel, user; if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) throw new Win32Exception(); return created.ToString(CultureInfo.InvariantCulture); } }
    public static bool MatchesProcessRole(string actualImage, string expectedBinary, string[] arguments, string powershellImage)
    {
        actualImage = actualImage.Replace('/', '\\'); expectedBinary = expectedBinary.Replace('/', '\\'); powershellImage = powershellImage.Replace('/', '\\');
        if (!expectedBinary.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase))
            return StringComparer.OrdinalIgnoreCase.Equals(actualImage, expectedBinary);
        if (!StringComparer.OrdinalIgnoreCase.Equals(actualImage, powershellImage)) return false;
        for (int i = 1; i + 1 < arguments.Length; i++)
            if (StringComparer.OrdinalIgnoreCase.Equals(arguments[i], "-File"))
                return StringComparer.OrdinalIgnoreCase.Equals(arguments[i + 1].Replace('/', '\\'), expectedBinary);
        return false;
    }
    static string[] ProcessArguments(uint pid)
    {
        using (var process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)) {
            int length;
            NtQueryInformationProcess(process, 60, IntPtr.Zero, 0, out length);
            if (length <= 0 || length > 131072) throw new Win32Exception();
            var buffer = Marshal.AllocHGlobal(length);
            try {
                if (NtQueryInformationProcess(process, 60, buffer, length, out length) < 0) throw new Win32Exception();
                var value = (UNICODE_STRING)Marshal.PtrToStructure(buffer, typeof(UNICODE_STRING));
                int count;
                var argv = CommandLineToArgvW(Marshal.PtrToStringUni(value.Buffer, value.Length / 2), out count);
                if (argv == IntPtr.Zero) throw new Win32Exception();
                try { var result = new string[count]; for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)); return result; }
                finally { LocalFree(argv); }
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }
    public static bool IsProcessIdentity(uint pid, string token, string expectedBinary, string expectedSha256, int expectedParentPid)
    {
        try {
            if (LivenessForPid(pid) != NativeProcessLiveness.Alive || CreationTokenForPid(pid) != token) return false;
            using (var p = Process.GetProcessById((int)pid)) {
                string actual = p.MainModule.FileName;
                string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!MatchesProcessRole(Path.GetFullPath(actual), Path.GetFullPath(expectedBinary), expectedBinary.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase) ? ProcessArguments(pid) : new string[0], shell)) return false;
            }
            if (!String.IsNullOrEmpty(expectedSha256)) using (var stream = File.OpenRead(expectedBinary)) using (var hash = SHA256.Create()) {
                if (!StringComparer.OrdinalIgnoreCase.Equals(BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", ""), expectedSha256)) return false;
            }
            // Parent ownership is checked by the supervisor manifest before control; a PID/token can never be enough.
            return expectedParentPid <= 1 || ParentPidForPid(pid) == expectedParentPid;
        } catch { return false; }
    }
    public static int ParentPidForPid(uint pid)
    {
        const uint TH32CS_SNAPPROCESS = 0x2; IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return -1;
        try { var entry = new PROCESSENTRY32 { Size = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) }; if (Process32First(snapshot, ref entry)) do { if (entry.Pid == pid) return (int)entry.ParentPid; } while (Process32Next(snapshot, ref entry)); return -1; } finally { CloseHandle(snapshot); }
    }
    internal static bool SendCtrlC() { return DedicatedConsoleReady && GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0); }
}
