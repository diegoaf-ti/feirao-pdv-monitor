// Windows-only storage. No private data is returned to callers.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Conecta.PdvRemoteEnrollment {
  public static class StorageV1 {
    [StructLayout(LayoutKind.Sequential)] private struct Attributes { public int Length; public IntPtr Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written; public uint VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl,uint revision,out IntPtr descriptor,out uint size);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateDirectoryW")] private static extern bool CreateDirectory(string path,ref Attributes attributes);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static void CreateDirectoryForUser(string path,string userSid) {
      if(Environment.OSVersion.Platform!=PlatformID.Win32NT) throw new InvalidOperationException("RemoteEnrollmentWindowsRequired");
      if(!System.Text.RegularExpressions.Regex.IsMatch(userSid??String.Empty,"\\AS-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+\\z")) throw new InvalidOperationException("RemoteEnrollmentInvalidMonitorSid");
      string sddl="O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;"+userSid+")"; IntPtr descriptor; uint size;
      if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
      try { Attributes attributes=new Attributes(); attributes.Length=Marshal.SizeOf(typeof(Attributes)); attributes.Descriptor=descriptor; if(!CreateDirectory(path,ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error()); } finally { LocalFree(descriptor); }
    }
    public static void AssertSingleLink(SafeFileHandle handle) { Info info; if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error()); if(info.Links!=1 || (info.Attributes&0x400)!=0) throw new InvalidOperationException("RemoteEnrollmentUnsafeFile"); }
  }
}
