using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
// The node supervisor is attached before it receives any assignment on stdin.
// Closing this handle (including supervisor death) kills its whole process tree.
public sealed class CogentSpecPolishProcessJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime; public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit; public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic; public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public CogentSpecPolishProcessJob(IntPtr process) {
        handle=CreateJobObject(IntPtr.Zero,null);
        if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits=new ExtendedLimits(); limits.Basic.Flags=0x2000;
        if(!SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits))) || !AssignProcessToJobObject(handle,process)) {
            int error=Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error);
        }
    }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } GC.SuppressFinalize(this); }
    ~CogentSpecPolishProcessJob() { Dispose(); }
}
