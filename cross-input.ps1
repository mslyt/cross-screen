#Requires -Version 5.1
<#
  跨屏输入 (Cross Input) —— 把手机里的文字输入到内线电脑
  电脑端唯一脚本：自带网页 + 键盘注入，无需安装任何软件、无需联网。

  用法：
    powershell -ExecutionPolicy Bypass -File cross-input.ps1          # 默认端口 8765
    powershell -ExecutionPolicy Bypass -File cross-input.ps1 -Port 9000
    powershell -ExecutionPolicy Bypass -File cross-input.ps1 -SelfTest # 测试键盘注入
#>
param(
    [int]$Port = 8765,
    [switch]$SelfTest
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ------------------------- 手机端网页 -------------------------
$html = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>跨屏输入</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin:0; background:#111417; color:#e8eaed;
         font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif; }
  .wrap { max-width:680px; margin:0 auto; padding:16px; }
  h1 { font-size:20px; margin:6px 0 12px; display:flex; align-items:center; gap:10px; }
  #st { font-size:12px; font-weight:normal; padding:3px 10px; border-radius:999px;
        background:#1e3a2b; color:#5fd08a; }
  #st.err { background:#3a1e1e; color:#f28b82; }
  textarea { width:100%; min-height:40vh; font-size:17px; line-height:1.55; padding:12px;
             border-radius:12px; border:1px solid #2a2f35; background:#1a1e22; color:#e8eaed;
             resize:vertical; outline:none; }
  textarea:focus { border-color:#2b6cf6; }
  .row { display:flex; gap:10px; margin-top:12px; align-items:center; }
  button { flex:1; font-size:17px; padding:14px 10px; border-radius:12px; border:1px solid #2a2f35;
           background:#22272c; color:#e8eaed; }
  button.primary { background:#2b6cf6; border-color:#2b6cf6; font-weight:600; }
  button:active { opacity:.72; }
  label { font-size:14px; color:#9aa0a6; display:flex; align-items:center; gap:6px; }
  select { font-size:15px; padding:8px; border-radius:8px; background:#1a1e22; color:#e8eaed;
           border:1px solid #2a2f35; }
  #log { font-size:14px; margin-top:12px; min-height:22px; color:#5fd08a; }
  #log.err { color:#f28b82; }
  .hint { font-size:13px; color:#9aa0a6; line-height:1.8; margin-top:14px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>跨屏输入 <span id="st">连接中…</span></h1>
  <textarea id="t" placeholder="在这里输入或粘贴要发送到电脑的文字…"></textarea>
  <div class="row">
    <button class="primary" onclick="send('type')">输入到电脑</button>
    <button onclick="send('clip')">复制到剪贴板</button>
  </div>
  <div class="row">
    <button style="flex:0 0 92px" onclick="clearAll()">清空</button>
    <label>速度
      <select id="d">
        <option value="0">快</option>
        <option value="2" selected>中</option>
        <option value="8">慢</option>
      </select>
    </label>
    <span style="flex:1"></span>
  </div>
  <div id="log"></div>
  <p class="hint">
    1. 先在电脑上点一下要输入的位置（出现光标）。<br>
    2. 在这里输入或粘贴文字，点「输入到电脑」。长文建议速度选「慢」。<br>
    3. 「复制到剪贴板」把文字放进电脑剪贴板，到目标处按 Ctrl+V。
  </p>
</div>
<script>
var ta = document.getElementById('t'),
    st = document.getElementById('st'),
    lg = document.getElementById('log');

function say(msg, isErr) { lg.textContent = msg; lg.className = isErr ? 'err' : ''; }
function clearAll() { ta.value = ''; say('已清空'); }

fetch('/ping').then(function () {
  st.textContent = '已连接'; st.className = '';
}).catch(function () {
  st.textContent = '未连接'; st.className = 'err';
});

function send(mode) {
  var text = ta.value;
  if (!text) { say('没有内容可发送', true); return; }
  say('发送中…');
  var body = 'mode=' + encodeURIComponent(mode) +
             '&delay=' + encodeURIComponent(document.getElementById('d').value) +
             '&text=' + encodeURIComponent(text);
  fetch('/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body
  }).then(function (r) { return r.json(); })
    .then(function (j) {
      if (j.ok) {
        say(mode === 'type' ? ('已在电脑输入 ' + j.count + ' 个字符') : '已复制到电脑剪贴板');
      } else {
        say('失败：' + (j.error || '未知错误'), true);
      }
    })
    .catch(function (e) { say('发送失败：' + e, true); });
}
</script>
</body>
</html>
'@

# ------------------------- 电脑端程序 -------------------------
$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class CrossInputServer
{
    private const uint INPUT_KEYBOARD   = 1;
    private const uint KEYEVENTF_KEYUP  = 0x0002;
    private const uint KEYEVENTF_UNICODE= 0x0004;
    private const ushort VK_RETURN      = 0x0D;
    private const ushort VK_TAB         = 0x09;
    private const uint CF_UNICODETEXT   = 13;
    private const uint GMEM_MOVEABLE    = 0x0002;

    // ---------------- SendInput ----------------
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private static INPUT MakeKey(ushort vk, bool up)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        return i;
    }

    private static INPUT MakeUni(char c, bool up)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = 0;
        i.u.ki.wScan = c;
        i.u.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
        return i;
    }

    private static void Fire(INPUT[] arr)
    {
        uint sent = SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
        if (sent != (uint)arr.Length)
            throw new Exception("SendInput 失败 (err=" + Marshal.GetLastWin32Error() + ")");
    }

    /// 把文本当作键盘输入打进当前焦点窗口。换行=回车，制表=Tab。
    public static int TypeText(string text, int delayMs)
    {
        if (text == null || text.Length == 0) return 0;
        int typed = 0;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            INPUT[] pair;
            if (c == '\r') { continue; }
            else if (c == '\n') { pair = new INPUT[] { MakeKey(VK_RETURN, false), MakeKey(VK_RETURN, true) }; }
            else if (c == '\t') { pair = new INPUT[] { MakeKey(VK_TAB, false), MakeKey(VK_TAB, true) }; }
            else { pair = new INPUT[] { MakeUni(c, false), MakeUni(c, true) }; }
            Fire(pair);
            typed++;
            if (delayMs > 0) Thread.Sleep(delayMs);
        }
        return typed;
    }

    // ---------------- 剪贴板 ----------------
    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseClipboard();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalUnlock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalFree(IntPtr hMem);

    public static bool SetClipboardText(string text)
    {
        for (int attempt = 0; attempt < 20; attempt++)
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    EmptyClipboard();
                    byte[] data = Encoding.Unicode.GetBytes(text + "\0");
                    IntPtr hMem = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)data.Length);
                    if (hMem == IntPtr.Zero) return false;
                    IntPtr p = GlobalLock(hMem);
                    if (p == IntPtr.Zero) { GlobalFree(hMem); return false; }
                    Marshal.Copy(data, 0, p, data.Length);
                    GlobalUnlock(hMem);
                    if (SetClipboardData(CF_UNICODETEXT, hMem) == IntPtr.Zero) { GlobalFree(hMem); return false; }
                    return true;
                }
                finally { CloseClipboard(); }
            }
            Thread.Sleep(50);
        }
        return false;
    }

    // ---------------- HTTP 服务 ----------------
    public static void Start(int port, string pageHtml)
    {
        TcpListener listener;
        try
        {
            listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
        }
        catch (Exception ex)
        {
            Console.WriteLine("[错误] 端口 " + port + " 无法监听：" + ex.Message);
            Console.WriteLine("       可能被占用，换个端口试试： -Port 9000");
            return;
        }

        Console.WriteLine("====================================================");
        Console.WriteLine("  跨屏输入 已启动   端口 " + port);
        Console.WriteLine("====================================================");
        List<string> urls = GetLocalUrls(port);
        for (int i = 0; i < urls.Count; i++) Console.WriteLine("  手机浏览器打开：" + urls[i]);
        if (urls.Count == 0) Console.WriteLine("  [!] 未检测到局域网地址，请检查网线 / USB 网络共享");
        Console.WriteLine("----------------------------------------------------");
        Console.WriteLine("  1. 手机连到同一网络（WiFi，或 USB 线 + 手机开 USB 网络共享）");
        Console.WriteLine("  2. 电脑上点击要输入的位置（光标闪烁）");
        Console.WriteLine("  3. 手机上输入文字 -> 点「输入到电脑」");
        Console.WriteLine("  按 Ctrl+C 退出。");
        Console.WriteLine("====================================================");

        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            try { Handle(client, pageHtml); }
            catch (Exception ex) { Console.WriteLine("[请求错误] " + ex.Message); }
            finally { try { client.Close(); } catch { } }
        }
    }

    private static List<string> GetLocalUrls(int port)
    {
        List<string> list = new List<string>();
        try
        {
            NetworkInterface[] nics = NetworkInterface.GetAllNetworkInterfaces();
            for (int i = 0; i < nics.Length; i++)
            {
                NetworkInterface nic = nics[i];
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                IPInterfaceProperties ip = nic.GetIPProperties();
                for (int j = 0; j < ip.UnicastAddresses.Count; j++)
                {
                    IPAddress a = ip.UnicastAddresses[j].Address;
                    if (a.AddressFamily != AddressFamily.InterNetwork) continue;
                    if (IPAddress.IsLoopback(a)) continue;
                    list.Add("http://" + a.ToString() + ":" + port + "/");
                }
            }
        }
        catch { }
        return list;
    }

    private static int IndexOfToken(byte[] data, int len, byte[] token)
    {
        for (int i = 0; i + token.Length <= len; i++)
        {
            bool ok = true;
            for (int j = 0; j < token.Length; j++) { if (data[i + j] != token[j]) { ok = false; break; } }
            if (ok) return i;
        }
        return -1;
    }

    private static void Handle(TcpClient client, string pageHtml)
    {
        NetworkStream ns = client.GetStream();
        ns.ReadTimeout = 30000;
        ns.WriteTimeout = 30000;

        MemoryStream ms = new MemoryStream();
        byte[] buf = new byte[8192];
        byte[] sep = Encoding.ASCII.GetBytes("\r\n\r\n");
        int headerEnd = -1;
        while (headerEnd < 0)
        {
            int n = ns.Read(buf, 0, buf.Length);
            if (n <= 0) return;
            ms.Write(buf, 0, n);
            if (ms.Length > 131072) return;
            headerEnd = IndexOfToken(ms.GetBuffer(), (int)ms.Length, sep);
        }

        string headerText = Encoding.ASCII.GetString(ms.GetBuffer(), 0, headerEnd);
        string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
        string[] req = lines[0].Split(' ');
        string method = req.Length > 0 ? req[0] : "GET";
        string path = req.Length > 1 ? req[1] : "/";

        int contentLength = 0;
        for (int i = 0; i < lines.Length; i++)
        {
            if (lines[i].StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
            {
                int v;
                if (int.TryParse(lines[i].Substring(15).Trim(), out v)) contentLength = v;
            }
        }

        MemoryStream bodyMs = new MemoryStream();
        int already = (int)ms.Length - (headerEnd + 4);
        if (already > 0) bodyMs.Write(ms.GetBuffer(), headerEnd + 4, already);
        while (bodyMs.Length < contentLength)
        {
            int n = ns.Read(buf, 0, buf.Length);
            if (n <= 0) break;
            bodyMs.Write(buf, 0, n);
        }

        string body = Encoding.UTF8.GetString(bodyMs.ToArray());
        string pathOnly = path;
        int q = pathOnly.IndexOf('?');
        if (q >= 0) pathOnly = pathOnly.Substring(0, q);

        if (method == "GET" && (pathOnly == "/" || pathOnly == "/index.html"))
        {
            WriteResponse(ns, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(pageHtml));
        }
        else if (method == "GET" && pathOnly == "/ping")
        {
            WriteResponse(ns, "200 OK", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("pong"));
        }
        else if (method == "POST" && pathOnly == "/send")
        {
            string json;
            try
            {
                Dictionary<string, string> f = ParseForm(body);
                string text = f.ContainsKey("text") ? f["text"] : "";
                string mode = f.ContainsKey("mode") ? f["mode"] : "type";
                int delay = 2;
                if (f.ContainsKey("delay")) { int d; if (int.TryParse(f["delay"], out d)) delay = d; }
                if (delay < 0) delay = 0;
                if (delay > 50) delay = 50;

                if (text.Length == 0)
                {
                    json = "{\"ok\":false,\"error\":\"内容为空\"}";
                }
                else if (mode == "clip")
                {
                    bool ok = SetClipboardText(text);
                    json = ok ? "{\"ok\":true,\"count\":" + text.Length + "}"
                              : "{\"ok\":false,\"error\":\"剪贴板被占用，请重试\"}";
                }
                else
                {
                    int typed = TypeText(text, delay);
                    Console.WriteLine("[输入] " + typed + " 个字符 -> 当前焦点窗口");
                    json = "{\"ok\":true,\"count\":" + typed + "}";
                }
            }
            catch (Exception ex)
            {
                json = "{\"ok\":false,\"error\":\"" + JsonEscape(ex.Message) + "\"}";
            }
            WriteResponse(ns, "200 OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
        }
        else
        {
            WriteResponse(ns, "404 Not Found", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("not found"));
        }
    }

    private static string JsonEscape(string s)
    {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
    }

    private static Dictionary<string, string> ParseForm(string body)
    {
        Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string[] pairs = body.Split('&');
        for (int i = 0; i < pairs.Length; i++)
        {
            int e = pairs[i].IndexOf('=');
            if (e < 0) continue;
            string k = Uri.UnescapeDataString(pairs[i].Substring(0, e).Replace('+', ' '));
            string v = Uri.UnescapeDataString(pairs[i].Substring(e + 1).Replace('+', ' '));
            d[k] = v;
        }
        return d;
    }

    private static void WriteResponse(NetworkStream ns, string status, string contentType, byte[] body)
    {
        string head = "HTTP/1.1 " + status + "\r\n" +
                      "Content-Type: " + contentType + "\r\n" +
                      "Content-Length: " + body.Length + "\r\n" +
                      "Cache-Control: no-store\r\n" +
                      "Connection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(head);
        ns.Write(hb, 0, hb.Length);
        ns.Write(body, 0, body.Length);
        ns.Flush();
    }

    /// 无害 API 探针：发一对“空按键”(VK 0)，不产生任何字符，
    /// 但能验证 SendInput 结构体大小/格式是否被系统接受。
    public static string ApiProbe()
    {
        INPUT[] arr = new INPUT[] { MakeKey(0, false), MakeKey(0, true) };
        uint sent = SendInput(2, arr, Marshal.SizeOf(typeof(INPUT)));
        if (sent == 2) return "OK";
        return "FAIL err=" + Marshal.GetLastWin32Error();
    }

    // ---------------- 自检 ----------------
    private const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
    private const int WS_VISIBLE = 0x10000000;
    private const int SW_SHOW = 5;
    private const int ES_MULTILINE = 0x0004;
    private const int ES_AUTOVSCROLL = 0x0040;
    private const int WM_USER = 0x0400;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(int exStyle, string cls, string title, int style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);

    public static void SelfTest()
    {
        Console.WriteLine("[自检] INPUT 结构体大小 = " + Marshal.SizeOf(typeof(INPUT)) + " 字节 (x64 应为 40)");
        Console.WriteLine("[自检] SendInput API 探针 = " + ApiProbe());
        Console.WriteLine("[自检] 创建测试窗口...");
        IntPtr h = CreateWindowEx(0, "EDIT", "", WS_OVERLAPPEDWINDOW | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL,
                                  10, 10, 420, 220, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        if (h == IntPtr.Zero) { Console.WriteLine("[自检] 窗口创建失败"); return; }
        ShowWindow(h, SW_SHOW);
        BringWindowToTop(h);

        uint me = GetCurrentThreadId();
        uint pid;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = GetWindowThreadProcessId(fg, out pid);
        AttachThreadInput(me, fgThread, true);
        SetForegroundWindow(h);
        SetFocus(h);
        BringWindowToTop(h);
        AttachThreadInput(me, fgThread, false);
        Thread.Sleep(300);

        if (GetForegroundWindow() != h)
        {
            Console.WriteLine("[自检] 无法取得前台窗口（可能不在图形会话中），跳过按键注入测试。");
            DestroyWindow(h);
            return;
        }

        string sample = "跨屏输入OK-123";
        Console.WriteLine("[自检] 注入测试文本: " + sample);
        TypeText(sample, 5);

        DateTime end = DateTime.UtcNow.AddMilliseconds(1200);
        MSG m;
        while (DateTime.UtcNow < end)
        {
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessage(ref m); }
            Thread.Sleep(10);
        }

        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        string got = sb.ToString();
        Console.WriteLine("[自检] 测试窗口收到: [" + got + "]");
        Console.WriteLine(got == sample ? "[自检] 键盘注入 : 成功" : "[自检] 键盘注入 : 失败(不符)");
        DestroyWindow(h);
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

if ($SelfTest) {
    [CrossInputServer]::SelfTest()
    return
}

[CrossInputServer]::Start($Port, $html)
