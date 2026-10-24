// Local pilot only. No network, installation, service control or existing-process termination.
// Win32 declarations and supervisor are original code; external VNC/tunnel binaries are not included.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace Conecta.PdvRemotePilot {
  public sealed class Evidence {
    public bool Detected, Supported, Interactive, Unlocked, NestedJobsSupported;
    public uint WindowsMajor, WindowsMinor, WindowsBuild;
    public ushort ServicePackMajor;
    public byte ProductType;
    public string WindowsVersion = "", Architecture = "", ProcessArchitecture = "", ClrVersion = "", CompatibilityReason = "", CompatibilityProfile = "",
      WindowsSessionId = "", UserSid = "", HostInstanceId = "";
  }
  public static class DesktopEvidence {
    private static readonly string Instance = Guid.NewGuid().ToString("D");
    // Pure policy: no P/Invoke, registry or compatibility-version helpers. A supported
    // profile still requires actual Windows/binary/antivirus homologation before release.
    public static string CompatibilityReason(uint major, uint minor, uint build, ushort servicePackMajor, byte productType,
      string nativeArchitecture, string processArchitecture, int clrMajor, int clrMinor) {
      if (productType != 1) return "RemoteUnsupportedWindowsProduct";
      bool windows7 = major == 6 && minor == 1;
      bool windows10Or11 = major == 10 && minor == 0 && build >= 10240;
      if (!windows7 && !windows10Or11) return "RemoteUnsupportedOperatingSystem";
      if (windows7 && (build != 7601 || servicePackMajor != 1)) return "RemoteWindows7ServicePackRequired";
      if ((nativeArchitecture != "x86" && nativeArchitecture != "x64") || (processArchitecture != "x86" && processArchitecture != "x64")) return "RemoteUnsupportedArchitecture";
      if (nativeArchitecture != processArchitecture) return "RemoteProcessArchitectureMismatch";
      // Native declarations retain old compiler syntax, but the remote transport
      // requires CLR 4. The outer host additionally verifies .NET Framework 4.6.2+.
      if (clrMajor != 4 || clrMinor < 0) return "RemoteUnsupportedClr";
      return "";
    }
    public static bool IsSupportedPlatform(uint major, uint minor, uint build, ushort servicePackMajor, byte productType,
      string nativeArchitecture, string processArchitecture, int clrMajor, int clrMinor) {
      return CompatibilityReason(major, minor, build, servicePackMajor, productType, nativeArchitecture, processArchitecture, clrMajor, clrMinor).Length == 0;
    }
    public static string PlatformProfile(uint major, uint minor, uint build, ushort servicePackMajor, byte productType,
      string nativeArchitecture, string processArchitecture, int clrMajor, int clrMinor) {
      if (!IsSupportedPlatform(major, minor, build, servicePackMajor, productType, nativeArchitecture, processArchitecture, clrMajor, clrMinor)) return "";
      return (major == 6 ? "win7-sp1-" : "win10plus-") + nativeArchitecture;
    }
    public static bool SupportsNestedJobs(uint major, uint minor) {
      // Windows 7 does not support assigning an inherited-job child to a second job.
      return major > 6 || (major == 6 && minor >= 2);
    }
    [DllImport("iphlpapi.dll", SetLastError=true)] private static extern uint GetExtendedTcpTable(IntPtr table, ref uint size, bool order, uint family, uint tableClass, uint reserved);
    public static bool LoopbackListenerOwnedBy(int port, int processId) {
      uint size = 0; GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 3, 0);
      if (size < 4 || size > 1048576) return false;
      IntPtr table = Marshal.AllocHGlobal((int)size);
      try {
        if (GetExtendedTcpTable(table, ref size, false, 2, 3, 0) != 0) return false;
        int count = Marshal.ReadInt32(table); if (count < 0 || 4L+24L*count > size) return false;
        for (int i=0; i<count; i++) {
          IntPtr row = new IntPtr(table.ToInt64()+4+24*i);
          int rowPort = (Marshal.ReadByte(row, 8)<<8) | Marshal.ReadByte(row, 9);
          if (rowPort == port) return Marshal.ReadInt32(row, 4) == 0x0100007f && Marshal.ReadInt32(row, 20) == processId;
        }
        return false;
      } finally { Marshal.FreeHGlobal(table); }
    }
    public static bool ProcessListenersSafe(int processId, int allowedLoopbackPort) {
      // Fail closed if either family cannot be inspected. No firewall is altered.
      for(int familyIndex=0; familyIndex<2; familyIndex++) {
        uint family = familyIndex == 0 ? 2U : 23U;
        uint size = 0; GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 3, 0);
        if (size < 4 || size > 1048576) return false;
        IntPtr table = Marshal.AllocHGlobal((int)size);
        try {
          if(GetExtendedTcpTable(table, ref size, false, family, 3, 0) != 0) return false;
          byte[] bytes = new byte[size]; Marshal.Copy(table, bytes, 0, (int)size);
          if(!ListenerTableSafe(bytes, family == 23, processId, allowedLoopbackPort)) return false;
        } finally { Marshal.FreeHGlobal(table); }
      }
      return true;
    }
    public static bool ListenerTableSafe(byte[] table, bool ipv6, int processId, int allowedLoopbackPort) {
      if(table == null || table.Length < 4 || table.Length > 1048576 || processId < 1 || allowedLoopbackPort < 0 || allowedLoopbackPort > 65535) return false;
      int width = ipv6 ? 56 : 24; int count = BitConverter.ToInt32(table, 0);
      if(count < 0 || 4L+(long)width*count > table.Length) return false;
      for(int i=0; i<count; i++) {
        int row = 4+width*i; int owner = BitConverter.ToInt32(table, row+(ipv6 ? 52 : 20));
        if(owner != processId) continue;
        if(ipv6 || allowedLoopbackPort == 0 || BitConverter.ToInt32(table, row+4) != 0x0100007f) return false;
        int port = (table[row+8]<<8) | table[row+9]; if(port != allowedLoopbackPort) return false;
      }
      return true;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct OsVersion {
      public uint Size, Major, Minor, Build, Platform;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
      public ushort ServicePackMajor, ServicePackMinor, SuiteMask;
      public byte ProductType, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)] private struct SystemInfo {
      public ushort Architecture, Reserved; public uint PageSize; public IntPtr MinimumAddress, MaximumAddress, Mask;
      public uint ProcessorCount, ProcessorType, AllocationGranularity; public ushort Level, Revision;
    }
    [DllImport("ntdll.dll", CharSet=CharSet.Unicode)] private static extern int RtlGetVersion(ref OsVersion info);
    [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out SystemInfo info);
    [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", SetLastError=true)] private static extern bool WTSQuerySessionInformation(IntPtr server, uint session, int information, out IntPtr buffer, out uint bytes);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] private static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool GetUserObjectInformation(IntPtr value, int index, StringBuilder text, uint length, out uint required);
    private static string DesktopName(IntPtr desktop) {
      if (desktop == IntPtr.Zero) return "";
      StringBuilder result = new StringBuilder(256); uint required;
      return GetUserObjectInformation(desktop, 2, result, 512, out required) ? result.ToString() : "";
    }
    public static Evidence Read() {
      Evidence result = new Evidence(); result.HostInstanceId = Instance;
      try {
        OsVersion version = new OsVersion(); version.Size = (uint)Marshal.SizeOf(typeof(OsVersion));
        SystemInfo system; GetNativeSystemInfo(out system);
        if (RtlGetVersion(ref version) != 0) return result;
        result.Detected = true; result.WindowsVersion = version.Major+"."+version.Minor+"."+version.Build;
        result.WindowsMajor = version.Major; result.WindowsMinor = version.Minor; result.WindowsBuild = version.Build;
        result.ServicePackMajor = version.ServicePackMajor; result.ProductType = version.ProductType;
        result.Architecture = system.Architecture == 9 ? "x64" : (system.Architecture == 0 ? "x86" : (system.Architecture == 12 ? "arm64" : "unsupported"));
        result.ProcessArchitecture = IntPtr.Size == 8 ? "x64" : (IntPtr.Size == 4 ? "x86" : "unsupported");
        result.ClrVersion = Environment.Version.ToString();
        result.CompatibilityReason = CompatibilityReason(version.Major, version.Minor, version.Build, version.ServicePackMajor,
          version.ProductType, result.Architecture, result.ProcessArchitecture, Environment.Version.Major, Environment.Version.Minor);
        result.Supported = result.CompatibilityReason.Length == 0;
        result.CompatibilityProfile = PlatformProfile(version.Major, version.Minor, version.Build, version.ServicePackMajor,
          version.ProductType, result.Architecture, result.ProcessArchitecture, Environment.Version.Major, Environment.Version.Minor);
        result.NestedJobsSupported = SupportsNestedJobs(version.Major, version.Minor);
        uint session = (uint)Process.GetCurrentProcess().SessionId;
        result.WindowsSessionId = session.ToString(); result.UserSid = WindowsIdentity.GetCurrent().User.Value;
        if (!result.Supported || !Environment.UserInteractive || session == 0 || session != WTSGetActiveConsoleSessionId()) return result;
        IntPtr buffer = IntPtr.Zero; uint size;
        try {
          if (!WTSQuerySessionInformation(IntPtr.Zero, session, 8, out buffer, out size) || size < 4 || Marshal.ReadInt32(buffer) != 0) return result;
        } finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
        result.Interactive = true;
        IntPtr input = OpenInputDesktop(0, false, 1);
        try {
          // Both desktops must be the visible Default desktop. Winlogon/UAC/unknown fail closed.
          result.Unlocked = String.Equals(DesktopName(input), "Default", StringComparison.OrdinalIgnoreCase)
            && String.Equals(DesktopName(GetThreadDesktop(GetCurrentThreadId())), "Default", StringComparison.OrdinalIgnoreCase);
        } finally { if (input != IntPtr.Zero) CloseDesktop(input); }
      } catch { result.Unlocked = false; result.Interactive = false; }
      return result;
    }
  }

  public sealed class ChildIdentity {
    public int ProcessId; public string Executable, CreatedUtc;
    internal IntPtr Handle;
  }
  public sealed class LeaseSupervisor : IDisposable {
    private readonly object gate = new object();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly List<ChildIdentity> children = new List<ChildIdentity>(2);
    // CreateProcess returns an owned handle even before identity/job checks succeed.
    // Keep those suspended children tracked until ownership transfers to children,
    // or their exit is positively confirmed. An uncertain cleanup stays blocking.
    private readonly List<IntPtr> uncontainedChildren = new List<IntPtr>(2);
    private readonly double maximumSeconds;
    private double heartbeatDeadline = 15;
    private readonly string session, sid;
    private Timer watchdog;
    private IntPtr job;
    private bool closed;
    private readonly bool nestedJobsSupported;
    private int tunnelPort;
    public string CloseReason { get; private set; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits { public BasicLimits BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo { public uint Size; public string Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags; public ushort ShowWindow, Reserved2; public IntPtr ReservedPointer, Input, Output, Error; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr security, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr job, int information, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool inJob);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateProcess(string executable, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);

    public LeaseSupervisor(int seconds, string sessionId, string userSid) {
      if (seconds < 1 || seconds > 900) throw new InvalidOperationException("RemoteInvalidLocalLifetime");
      Evidence evidence = DesktopEvidence.Read();
      if (!evidence.Unlocked || evidence.WindowsSessionId != sessionId || evidence.UserSid != userSid) throw new InvalidOperationException("RemoteLocalSessionChanged");
      nestedJobsSupported = evidence.NestedJobsSupported;
      bool inheritedJob;
      if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inheritedJob)) throw new InvalidOperationException("RemoteJobInspectionFailed");
      // Fail before launching anything on Windows 7 if the monitor itself is under
      // another job. Do not request BREAKAWAY, weaken kill-on-close, or reuse its job.
      if (!nestedJobsSupported && inheritedJob) throw new InvalidOperationException("RemoteNestedJobUnsupported");
      session = sessionId; sid = userSid; maximumSeconds = seconds; CloseReason = "";
      job = CreateJobObject(IntPtr.Zero, null);
      if (job == IntPtr.Zero) throw new InvalidOperationException("RemoteJobUnavailable");
      ExtendedLimits limits = new ExtendedLimits(); limits.BasicLimitInformation.LimitFlags = 0x2000 | 0x8; limits.BasicLimitInformation.ActiveProcessLimit = 2;
      if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { CloseHandle(job); job = IntPtr.Zero; throw new InvalidOperationException("RemoteJobUnavailable"); }
      watchdog = new Timer(Check, null, 500, 500);
    }
    public bool Closed { get { lock(gate) { return closed; } } }
    private bool ProcessesStoppedLocked() {
      if (!closed) return false;
      foreach (ChildIdentity child in children) if (WaitForSingleObject(child.Handle, 0) != 0) return false;
      foreach (IntPtr handle in uncontainedChildren) if (WaitForSingleObject(handle, 0) != 0) return false;
      return true;
    }
    public bool ProcessesStopped { get { lock(gate) { return ProcessesStoppedLocked(); } } }
    public ChildIdentity[] Children { get { lock(gate) { return children.ToArray(); } } }
    public void SetTunnelPort(int port) { lock(gate) { if(closed || children.Count != 0 || tunnelPort != 0 || port < 1024 || port > 65535) throw new InvalidOperationException("RemoteInvalidTunnelPort"); tunnelPort = port; } }
    private static string ChildEnvironmentDirectory(string value) {
      // Pure Windows-path validation, independent of the machine running tests.
      // Never expand inherited variables or accept a PATH-list as one directory.
      if (String.IsNullOrEmpty(value) || value.Length > 32760 || value.Length < 3
        || !((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z'))
        || value[1] != ':' || value[2] != '\\') throw new InvalidOperationException("RemoteChildEnvironmentPath");
      for (int i=0; i<value.Length; i++) {
        char character = value[i];
        if (Char.IsControl(character) || character == '"' || character == '%' || character == ';'
          || character == '=' || character == '/' || character == '<' || character == '>' || character == '|'
          || character == '?' || character == '*' || (character == ':' && i != 1)) throw new InvalidOperationException("RemoteChildEnvironmentPath");
      }
      string normalized = value.TrimEnd('\\');
      if (normalized.Length < 3) throw new InvalidOperationException("RemoteChildEnvironmentPath");
      foreach (string segment in normalized.Substring(3).Split('\\')) {
        if (segment.Length == 0 || segment == "." || segment == ".." || segment.EndsWith(".", StringComparison.Ordinal)
          || segment.EndsWith(" ", StringComparison.Ordinal)) throw new InvalidOperationException("RemoteChildEnvironmentPath");
      }
      return normalized;
    }
    public static string BuildChildEnvironmentBlock(string windowsDirectory, string systemDirectory, string executableDirectory,
      string userProfile, string applicationData, string localApplicationData) {
      // Only explicit OS/known-folder paths enter this block. No GetEnvironmentVariables,
      // inherited PATH, OpenSSL settings, profiler, COM or compatibility-hook variables.
      string windows = ChildEnvironmentDirectory(windowsDirectory);
      string system = ChildEnvironmentDirectory(systemDirectory);
      string executable = ChildEnvironmentDirectory(executableDirectory);
      string profile = ChildEnvironmentDirectory(userProfile);
      string roaming = ChildEnvironmentDirectory(applicationData);
      string local = ChildEnvironmentDirectory(localApplicationData);
      if (!String.Equals(system, windows+"\\System32", StringComparison.OrdinalIgnoreCase)
        && !String.Equals(system, windows+"\\SysWOW64", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("RemoteChildEnvironmentSystemPath");
      SortedDictionary<string,string> values = new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
      values.Add("APPDATA", roaming); values.Add("LOCALAPPDATA", local);
      // NUL disables external configuration; engine/provider lookup is confined to
      // the dedicated, administratively protected executable directory.
      values.Add("OPENSSL_CONF", "NUL"); values.Add("OPENSSL_ENGINES", executable); values.Add("OPENSSL_MODULES", executable);
      values.Add("PATH", system+";"+windows); values.Add("SystemDrive", windows.Substring(0,2));
      values.Add("SystemRoot", windows); values.Add("TEMP", local+"\\Temp"); values.Add("TMP", local+"\\Temp");
      values.Add("USERPROFILE", profile); values.Add("WINDIR", windows);
      StringBuilder result = new StringBuilder();
      foreach (KeyValuePair<string,string> pair in values) result.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
      result.Append('\0');
      if (result.Length > 32760) throw new InvalidOperationException("RemoteChildEnvironmentTooLarge");
      return result.ToString();
    }
    public ChildIdentity StartChild(string executable, string arguments, string directory) {
      lock(gate) {
        if (closed || clock.Elapsed.TotalSeconds >= maximumSeconds || children.Count >= 2 || uncontainedChildren.Count != 0 || tunnelPort == 0) throw new InvalidOperationException("RemoteSupervisorClosed");
        StartupInfo startup = new StartupInfo(); startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
        ProcessInformation process = new ProcessInformation();
        IntPtr environment = IntPtr.Zero;
        try {
          string environmentBlock = BuildChildEnvironmentBlock(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows), Environment.SystemDirectory, directory,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
          environment = Marshal.StringToHGlobalUni(environmentBlock);
          // CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW.
          // The owned child is still checked and assigned to our Job before resume.
          if (executable.IndexOf('"') >= 0 || !CreateProcess(executable, new StringBuilder("\""+executable+"\" "+arguments), IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000 | 0x400, environment, directory, ref startup, out process)) throw new InvalidOperationException("RemoteChildStartFailed");
        } finally { if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment); }
        uncontainedChildren.Add(process.Process);
        bool owned = false;
        try {
          long created, exited, kernel, user; StringBuilder image = new StringBuilder(32768); uint count = 32768;
          if (!GetProcessTimes(process.Process, out created, out exited, out kernel, out user) || !QueryFullProcessImageName(process.Process, 0, image, ref count) || !String.Equals(image.ToString(), executable, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("RemoteChildIdentityMismatch");
          // Check the actual suspended child as well: a parent job can have been
          // attached after supervisor construction. Never resume an unowned child.
          bool inheritedJob;
          if (!IsProcessInJob(process.Process, IntPtr.Zero, out inheritedJob)) throw new InvalidOperationException("RemoteJobInspectionFailed");
          if (!nestedJobsSupported && inheritedJob) throw new InvalidOperationException("RemoteNestedJobUnsupported");
          if (!AssignProcessToJobObject(job, process.Process)) throw new InvalidOperationException("RemoteChildJobFailed");
          ChildIdentity identity = new ChildIdentity(); identity.ProcessId = (int)process.ProcessId; identity.Executable = image.ToString(); identity.CreatedUtc = DateTime.FromFileTimeUtc(created).ToString("o"); identity.Handle = process.Process;
          children.Add(identity); owned = true; uncontainedChildren.Remove(process.Process);
          if (ResumeThread(process.Thread) == UInt32.MaxValue) { StopLocked("TransportFailed"); throw new InvalidOperationException("RemoteChildResumeFailed"); }
          return identity;
        } finally {
          CloseHandle(process.Thread);
          if (!owned) {
            StopLocked("TransportFailed");
            if (WaitForSingleObject(process.Process, 0) == 0) { CloseHandle(process.Process); uncontainedChildren.Remove(process.Process); }
          }
        }
      }
    }
    public void Heartbeat() {
      lock(gate) { if (closed || clock.Elapsed.TotalSeconds >= maximumSeconds || clock.Elapsed.TotalSeconds >= heartbeatDeadline) { StopLocked("LeaseExpired"); throw new InvalidOperationException("RemoteSupervisorClosed"); } heartbeatDeadline = Math.Min(maximumSeconds, clock.Elapsed.TotalSeconds+15); }
    }
    private void Check(object ignored) {
      lock(gate) {
        if (closed) return;
        if (clock.Elapsed.TotalSeconds >= maximumSeconds) { StopLocked("LeaseExpired"); return; }
        if (clock.Elapsed.TotalSeconds >= heartbeatDeadline) { StopLocked("AuthorizationLost"); return; }
        Evidence evidence = DesktopEvidence.Read();
        if (!evidence.Unlocked || evidence.WindowsSessionId != session || evidence.UserSid != sid) { StopLocked("LocalSessionChanged"); return; }
        for(int i=0; i<children.Count; i++) {
          ChildIdentity child = children[i];
          if(WaitForSingleObject(child.Handle, 0) != 258) { StopLocked("TransportProcessExited"); return; }
          if(!DesktopEvidence.ProcessListenersSafe(child.ProcessId, i == 0 ? tunnelPort : 0)) { StopLocked("TransportUnsafeListener"); return; }
        }
      }
    }
    private void StopLocked(string reason) {
      if (!closed) {
        closed = true; CloseReason = reason;
        if (job != IntPtr.Zero) { TerminateJobObject(job, 1); CloseHandle(job); job = IntPtr.Zero; }
      }
      // Retry a prior uncertain cleanup by the CreateProcess handle alone. Never
      // use persisted PIDs, release a live handle, or resume outside our Job.
      foreach (IntPtr handle in uncontainedChildren) if (WaitForSingleObject(handle, 0) != 0) TerminateProcess(handle, 1);
      foreach(ChildIdentity child in children) WaitForSingleObject(child.Handle, 2000);
      foreach(IntPtr handle in uncontainedChildren) WaitForSingleObject(handle, 2000);
    }
    public void Stop(string reason) { lock(gate) { StopLocked(reason); } }
    public void Dispose() {
      lock(gate) {
        StopLocked("HostClosed");
        if (!ProcessesStoppedLocked()) throw new InvalidOperationException("RemoteOwnProcessesStillRunning");
        if (watchdog != null) { watchdog.Dispose(); watchdog = null; }
        foreach(ChildIdentity child in children) CloseHandle(child.Handle); children.Clear();
        foreach(IntPtr handle in uncontainedChildren) CloseHandle(handle); uncontainedChildren.Clear();
      }
    }
  }
}
