<#
SETUP: .\setup.ps1
RUN:
    .\cli.ps1 mastery
    .\cli.ps1 bot
    .\cli.ps1 purge
    .\cli.ps1 snap
    .\cli.ps1 path\to\custom.yaml
STOP: Ctrl+C or lose focus.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action,
    [switch]$Dump
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Assembly loading
# ============================================================================
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:_dllDir = Join-Path $PSScriptRoot 'lib'
foreach ($dll in @('OpenCvSharp.dll', 'OpenCvSharpExtern.dll', 'YamlDotNet.dll')) {
    if (-not (Test-Path (Join-Path $script:_dllDir $dll))) {
        Write-Error "$dll not found in $script:_dllDir -- run .\setup.ps1 first."
        exit 1
    }
}

$env:PATH = "$script:_dllDir;$env:PATH"
[System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $script:_dllDir 'OpenCvSharpExtern.dll')) | Out-Null
Add-Type -Path (Join-Path $script:_dllDir 'OpenCvSharp.dll') -ErrorAction SilentlyContinue
Add-Type -Path (Join-Path $script:_dllDir 'YamlDotNet.dll') -ErrorAction SilentlyContinue

# ============================================================================
# YAML helper
# ============================================================================
function Read-Yaml([string]$path) {
    $text = Get-Content $path -Raw
    $deserializer = [YamlDotNet.Serialization.DeserializerBuilder]::new().Build()
    return $deserializer.Deserialize[object]($text)
}

# ============================================================================
# Config loading
# ============================================================================
$script:Config = Read-Yaml (Join-Path $PSScriptRoot 'config.yaml')

$script:WINDOW_TITLE = $Config['window_title']
$script:REFRAME_INTERVAL = [double]$Config['reframe_interval']
$script:KEY_INTERVAL = [double]$Config['key_interval']
$script:POLL_INTERVAL = [double]$Config['poll_interval']
$script:VERIFY_TIMEOUT = [double]$Config['verify_timeout']

$grid = $Config['grid']
$script:CENTER_X_C0 = [double]$grid['center_x_c0']
$script:CENTER_Y_R0 = [double]$grid['center_y_r0']
$script:COL_X_STEP = [double]$grid['col_x_step']
$script:ROW_Y_STEP = [double]$grid['row_y_step']
$script:SLOT_HALF_W = [double]$grid['slot_half_w']
$script:SLOT_HALF_H = [double]$grid['slot_half_h']

$edge = $Config['edge']
$script:EDGE_STDDEV_THRESHOLD = [double]$edge['stddev_threshold']
$script:EDGE_WIDTH_FRAC = [double]$edge['width_frac']

# ============================================================================
# Templates loading
# ============================================================================
$script:TemplatesYaml = Read-Yaml (Join-Path $PSScriptRoot 'templates\thresholds.yaml')

# ============================================================================
# P/Invoke (Win32)
# ============================================================================
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class ForzaWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFO {
        public uint cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFO mi);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")]
    public static extern void CopyMemory(IntPtr dst, IntPtr src, uint count);

    public const byte VK_W = 0x57;
    public const byte VK_SPACE = 0x20;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    public static string GetTitle(IntPtr hwnd) {
        int len = GetWindowTextLength(hwnd);
        if (len == 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int[] GetMonitorDimensions(IntPtr hwnd) {
        IntPtr hMon = MonitorFromWindow(hwnd, 2);
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
        GetMonitorInfo(hMon, ref mi);
        return new int[] {
            mi.rcMonitor.Right - mi.rcMonitor.Left,
            mi.rcMonitor.Bottom - mi.rcMonitor.Top
        };
    }

    public static int[] GetClientArea(IntPtr hwnd) {
        RECT r;
        GetClientRect(hwnd, out r);
        POINT pt = new POINT { X = 0, Y = 0 };
        ClientToScreen(hwnd, ref pt);
        return new int[] { pt.X, pt.Y, r.Right - r.Left, r.Bottom - r.Top };
    }
}
'@ -ErrorAction SilentlyContinue

# ============================================================================
# State
# ============================================================================
$script:_hwnd = [IntPtr]::Zero
$script:_dpiAwareSet = $false
$script:_lastScreen = $null
$script:_templates = @{}
$script:_scaledCache = @{}
$script:_dumpDir = $null
$script:_dumpToDisk = $false
$script:_logFile = $null
$script:_logLevel = 'INFO'
$script:_lastDetectMatchAt = $null

$script:YELLOW_LOWER = [OpenCvSharp.Scalar]::new(20, 200, 200)
$script:YELLOW_UPPER = [OpenCvSharp.Scalar]::new(32, 255, 255)
$script:FOCUS_LOWER = [OpenCvSharp.Scalar]::new(35, 150, 150)
$script:FOCUS_UPPER = [OpenCvSharp.Scalar]::new(75, 255, 255)

$SENDKEYS_MAP = @{
    enter     = '{ENTER}'
    escape    = '{ESC}'
    space     = ' '
    up        = '{UP}'
    down      = '{DOWN}'
    left      = '{LEFT}'
    right     = '{RIGHT}'
    pageup    = '{PGUP}'
    pagedown  = '{PGDN}'
    backspace = '{BACKSPACE}'
    x         = 'x'
    y         = 'y'
    w         = 'w'
}

$CAPTURE_RETRIES = 5
$DUMP_DIR_ROOT = $PSScriptRoot

# ============================================================================
# Logging
# ============================================================================
$script:_currentStep = $null

function Write-Log([string]$Level, [string]$Msg) {
    if ($Level -eq 'DEBUG' -and $script:_logLevel -ne 'DEBUG') {
        return 
    }
    if ($script:_currentStep) {
        $prefix = "[$($script:_currentStep)] "
    } else {
        $prefix = ''
    }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $($Level.PadRight(7)) $prefix$Msg"
    Write-Host $line
    if ($script:_logFile) {
        Add-Content -Path $script:_logFile -Value $line -Encoding UTF8 
    }
}

function Log-Info([string]$m) {
    Write-Log 'INFO' $m 
}
function Log-Debug([string]$m) {
    Write-Log 'DEBUG' $m 
}
function Log-Warning([string]$m) {
    Write-Log 'WARNING' $m 
}
function Log-Error([string]$m) {
    Write-Log 'ERROR' $m 
}
function Is-DebugEnabled {
    return $script:_logLevel -eq 'DEBUG' 
}

# ============================================================================
# Window helpers
# ============================================================================
function Get-GameWindow {
    if ($script:_hwnd -eq [IntPtr]::Zero) {
        $proc = Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.Contains($script:WINDOW_TITLE) } | Select-Object -First 1
        if ($proc) {
            $script:_hwnd = $proc.MainWindowHandle 
        }
    }

    return $script:_hwnd
}

function Is-WindowFocused {
    try {
        $fg = [ForzaWin32]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) {
            return $false 
        }
        return ([ForzaWin32]::GetTitle($fg)).Contains($script:WINDOW_TITLE)
    } catch {
        return $false 
    }
}

# ============================================================================
# Common helpers
# ============================================================================
function Wait-ForRefresh([double]$sec = $script:REFRAME_INTERVAL) {
    Start-Sleep -Milliseconds ([int]($sec * 1000))
}

function Wait-PollTick {
    Start-Sleep -Milliseconds ([int]($script:POLL_INTERVAL * 1000))
}

function Wait-Countdown([double]$seconds, [string]$label = 'Starting') {
    $full = [int]$seconds
    for ($r = $full; $r -gt 0; $r--) {
        Write-Host "$label in ${r}..."
        Start-Sleep -Seconds 1
    }

    $tail = $seconds - $full
    if ($tail -gt 0) {
        Start-Sleep -Milliseconds ([int]($tail * 1000)) 
    }
}

# ============================================================================
# Input helpers
# ============================================================================
function Press-Key([string]$Key) {
    Log-Debug "press $Key"
    $sk = $SENDKEYS_MAP[$Key]; if (-not $sk) {
        $sk = $Key 
    }
    [System.Windows.Forms.SendKeys]::SendWait($sk)
    Start-Sleep -Milliseconds ([int]($script:KEY_INTERVAL * 1000))
}

function Repeat-Key([string]$Key, [int]$Times) {
    for ($i = 0; $i -lt $Times; $i++) {
        Press-Key $Key
    }
}

function Hold-Key([string]$Key) {
    [ForzaWin32]::keybd_event([byte][char]$Key, 0, 0, [UIntPtr]::Zero)
    Wait-PollTick
}

function Release-Key([string]$Key) {
    [ForzaWin32]::keybd_event([byte][char]$Key, 0, [ForzaWin32]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Is-KeyHeld([string]$Key) {
    return ([ForzaWin32]::GetAsyncKeyState([int][byte][char]$Key) -band 0x8000) -ne 0
}

# ============================================================================
# Screen capture
# ============================================================================
function Ensure-DpiAware {
    if (-not $script:_dpiAwareSet) {
        try {
            [ForzaWin32]::SetProcessDPIAware() | Out-Null 
        } catch {
        }
        $script:_dpiAwareSet = $true
    }
}

function Get-MonitorSize([IntPtr]$hwnd) {
    return [ForzaWin32]::GetMonitorDimensions($hwnd)
}

function Get-ClientRect([IntPtr]$hwnd) {
    return [ForzaWin32]::GetClientArea($hwnd)
}

function Capture-Frame([double]$wait = $script:REFRAME_INTERVAL) {
    if ($wait -gt 0) {
        Wait-ForRefresh $wait
    }
    Ensure-DpiAware
    $hwnd = Get-GameWindow
    $scr = Get-MonitorSize $hwnd
    if ($null -eq $script:_lastScreen -or $script:_lastScreen[0] -ne $scr[0] -or $script:_lastScreen[1] -ne $scr[1]) {
        Log-Info "Game window on monitor $($scr[0])x$($scr[1])"
        $script:_lastScreen = $scr
    }

    $cr = Get-ClientRect $hwnd
    $cx = $cr[0]
    $cy = $cr[1]
    $cw = $cr[2]
    $ch = $cr[3]
    $lastErr = $null
    for ($att = 0; $att -lt $CAPTURE_RETRIES; $att++) {
        try {
            $bmp = [System.Drawing.Bitmap]::new($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($cx, $cy, 0, 0, [System.Drawing.Size]::new($cw, $ch))
            $g.Dispose()
            $rect = [System.Drawing.Rectangle]::new(0, 0, $cw, $ch)
            $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $mat = [OpenCvSharp.Mat]::new($ch, $cw, [OpenCvSharp.MatType]::CV_8UC4)
            [ForzaWin32]::CopyMemory($mat.Data, $data.Scan0, [uint]($data.Stride * $ch))
            $bmp.UnlockBits($data); $bmp.Dispose()
            $bgr = [OpenCvSharp.Mat]::new()
            [OpenCvSharp.Cv2]::CvtColor($mat, $bgr, [OpenCvSharp.ColorConversionCodes]::BGRA2BGR)
            $mat.Dispose()
            return $bgr
        } catch {
            $lastErr = $_
            Log-Warning "Capture attempt $($att+1)/$CAPTURE_RETRIES failed: $lastErr"
            Wait-PollTick
        }
    }

    throw "capture failed after $CAPTURE_RETRIES attempts: $lastErr"
}

# ============================================================================
# Template loading + matching
# ============================================================================
function Get-Template([string]$name) {
    if (-not $script:_templates.ContainsKey($name)) {
        if (-not $script:TemplatesYaml.ContainsKey($name)) {
            Log-Error "Template '$name' not found in thresholds.yaml"
            exit 1
        }

        $pngPath = Join-Path $PSScriptRoot "templates\t_$name.png"
        if (-not (Test-Path $pngPath)) {
            Log-Error "Template file not found: $pngPath"
            exit 1
        }

        $script:_templates[$name] = [OpenCvSharp.Cv2]::ImRead($pngPath, [OpenCvSharp.ImreadModes]::Grayscale)
    }

    return $script:_templates[$name]
}

function Get-Threshold([string]$name) {
    if (-not $script:TemplatesYaml.ContainsKey($name)) {
        Log-Error "No template '$name'"
        exit 1
    }

    return [double]$script:TemplatesYaml[$name]
}

function Get-ScaledTemplate([string]$name, [int]$frameW) {
    $key = "${name}_${frameW}"
    if ($script:_scaledCache.ContainsKey($key)) {
        return $script:_scaledCache[$key]
    }

    $tmpl = Get-Template $name
    $scale = $frameW / 1280.0
    if ([Math]::Abs($scale - 1.0) -lt 0.01) {
        $script:_scaledCache[$key] = $tmpl
        return $tmpl
    }

    $nh = [Math]::Max(1, [int][Math]::Round($tmpl.Rows * $scale))
    $nw = [Math]::Max(1, [int][Math]::Round($tmpl.Cols * $scale))
    if ($scale -lt 1.0) {
        $interp = [OpenCvSharp.InterpolationFlags]::Area
    } else {
        $interp = [OpenCvSharp.InterpolationFlags]::Linear
    }
    $resized = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::Resize($tmpl, $resized, [OpenCvSharp.Size]::new($nw, $nh), 0, 0, $interp)
    $script:_scaledCache[$key] = $resized
    return $resized
}

function Get-MatchScore([OpenCvSharp.Mat]$regionGray, [string]$name, [int]$frameW = 0) {
    if ($frameW -eq 0) {
        $frameW = $regionGray.Cols 
    }
    $tmpl = Get-ScaledTemplate $name $frameW
    if ($tmpl.Rows -gt $regionGray.Rows -or $tmpl.Cols -gt $regionGray.Cols) {
        return 0.0 
    }
    $res = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::MatchTemplate($regionGray, $tmpl, $res, [OpenCvSharp.TemplateMatchModes]::CCoeffNormed)
    $mn = 0.0; $mx = 0.0
    $mnL = [OpenCvSharp.Point]::new(0, 0); $mxL = [OpenCvSharp.Point]::new(0, 0)
    [OpenCvSharp.Cv2]::MinMaxLoc($res, [ref]$mn, [ref]$mx, [ref]$mnL, [ref]$mxL)
    $res.Dispose()
    return $mx
}

function Match-Template([OpenCvSharp.Mat]$gray, [string]$name, [int]$frameW = 0) {
    $score = Get-MatchScore $gray $name $frameW
    return @{ Score = $score; Matched = ($score -gt (Get-Threshold $name)) }
}

function Format-TemplateExpression($expr) {
    if ($expr -is [string]) {
        return $expr 
    }

    $keys = @($expr.Keys)
    $op = $keys[0].ToString()
    $items = @($expr[$op])

    $parts = @()
    foreach ($item in $items) {
        $parts += (Format-TemplateExpression $item)
    }
    if ($op -eq 'all') {
        $joiner = ' and ' 
    } else {
        $joiner = ' or ' 
    }
    return '(' + ($parts -join $joiner) + ')'
}

function Match-TemplateExpression([OpenCvSharp.Mat]$gray, $expr, [bool]$debug = $false, [int]$frameW = 0) {
    if ($expr -is [string]) {
        $r = Match-Template $gray $expr $frameW
        return [pscustomobject]@{
            Matched = [bool]$r.Matched
            Details = @([pscustomobject]@{
                    Name    = $expr
                    Score   = [double]$r.Score
                    Matched = [bool]$r.Matched
                })
        }
    }

    $keys = @($expr.Keys)
    $op = $keys[0].ToString()
    $items = @($expr[$op])

    $details = @()
    $matched = ($op -eq 'all')
    foreach ($item in $items) {
        $r = Match-TemplateExpression $gray $item -debug $debug -frameW $frameW
        $details += $r.Details
        if ($op -eq 'all') {
            $matched = $matched -and [bool]$r.Matched
            if (-not $matched -and -not $debug) {
                break 
            }
        } else {
            $matched = $matched -or [bool]$r.Matched
            if ($matched -and -not $debug) {
                break 
            }
        }
    }

    return [pscustomobject]@{ Matched = [bool]$matched; Details = $details }
}

function Format-TemplateDetails($details) {
    $parts = @()
    foreach ($d in $details) {
        if ($d.Matched) {
            $state = 'hit' 
        } else {
            $state = 'miss' 
        }
        $parts += ('{0}={1:F3}:{2}' -f $d.Name, $d.Score, $state)
    }
    return $parts -join ', '
}

function Get-TemplateTag([string]$label) {
    $tag = ($label -replace '[^A-Za-z0-9_-]+', '_').Trim('_')
    if ($tag.Length -gt 80) {
        $tag = $tag.Substring(0, 80) 
    }
    if ($tag.Length -eq 0) {
        return 'match' 
    }
    return $tag
}

function Wait-ForTemplate($templateExpr, [double]$timeout = $script:VERIFY_TIMEOUT, [string]$onMiss = $null) {
    $label = Format-TemplateExpression $templateExpr
    $start = [DateTime]::Now

    while (([DateTime]::Now - $start).TotalSeconds -lt $timeout) {
        $frame = Capture-Frame -wait 0
        $gray = [OpenCvSharp.Mat]::new()
        [OpenCvSharp.Cv2]::CvtColor($frame, $gray, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)
        $debug = Is-DebugEnabled
        $r = Match-TemplateExpression $gray $templateExpr -debug $debug
        if ($debug) {
            Log-Debug "polling ${label}: $(Format-TemplateDetails $r.Details) matched=$($r.Matched)"
        }

        if ($r.Matched) {
            $el = ([DateTime]::Now - $start).TotalSeconds
            Log-Info "$label verified ($(Format-TemplateDetails $r.Details), took $([Math]::Round($el,1))s)"
            $gray.Dispose()
            $frame.Dispose()
            return
        }

        $gray.Dispose()
        $frame.Dispose()

        Wait-PollTick

        if ($onMiss) {
            Press-Key $onMiss
        }
    }

    $frame = Capture-Frame -wait 0
    Write-Diagnostics $frame "$(Get-TemplateTag $label)_timeout"
    $frame.Dispose()
    Log-Error "Did not detect $label within $([int]$timeout)s; stopping"
    exit 1
}

# ============================================================================
# Dump helpers
# ============================================================================
function Ensure-DumpDir {
    if ($null -eq $script:_dumpDir) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:_dumpDir = Join-Path $DUMP_DIR_ROOT "${ts}_dump"
    }

    New-Item -Path $script:_dumpDir -ItemType Directory -Force | Out-Null
}

function Save-DumpCells($cells, [string]$tag) {
    if (-not $script:_dumpToDisk) {
        return 
    }
    Ensure-DumpDir
    for ($c = 0; $c -lt 4; $c++) {
        for ($r = 0; $r -lt 3; $r++) {
            $cell = $cells[$c][$r]
            [void][OpenCvSharp.Cv2]::ImWrite((Join-Path $script:_dumpDir "${tag}_c${c}r${r}_slot.png"), $cell.Bgr)
            [void][OpenCvSharp.Cv2]::ImWrite((Join-Path $script:_dumpDir "${tag}_c${c}r${r}_brand_new.png"), $cell.YellowBgr)
        }
    }
}

function Write-Diagnostics([OpenCvSharp.Mat]$frame, [string]$tag) {
    $g = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::CvtColor($frame, $g, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)
    Ensure-DumpDir
    $p = Join-Path $script:_dumpDir "stuck_${tag}_$([int][DateTimeOffset]::Now.ToUnixTimeSeconds()).png"
    [void][OpenCvSharp.Cv2]::ImWrite($p, $frame)
    Log-Warning "Stuck ($tag) -- frame saved to $(Split-Path $p -Leaf)"
    Log-Warning 'Template scores:'
    foreach ($kv in $script:TemplatesYaml.GetEnumerator()) {
        $n = $kv.Key.ToString()
        $sc = Get-MatchScore $g $n
        $th = [double]$kv.Value
        if ($sc -gt $th) {
            $mark = ' ABOVE'
        } else {
            $mark = ''
        }
        Log-Warning ('  {0,-16} = {1:F3} (th={2:F2}){3}' -f $n, $sc, $th, $mark)
    }

    $g.Dispose()
}

function Dispose-GridCells($cells) {
    for ($c = 0; $c -lt 4; $c++) {
        for ($r = 0; $r -lt 3; $r++) {
            $cell = $cells[$c][$r]
            foreach ($name in @('Bgr', 'Gray', 'YellowBgr')) {
                if ($cell.$name) {
                    $cell.$name.Dispose() 
                }
            }
        }
    }
}

# ============================================================================
# Grid helpers
# ============================================================================
function Get-ScaledSlot([int]$h, [int]$w, [int]$col, [int]$row) {
    $cx = ($script:CENTER_X_C0 + $col * $script:COL_X_STEP) * $w
    $cy = ($script:CENTER_Y_R0 + $row * $script:ROW_Y_STEP) * $h
    $hw = $script:SLOT_HALF_W * $w; $hh = $script:SLOT_HALF_H * $h
    return @([int]($cx - $hw), [int]($cy - $hh), [int]($cx + $hw), [int]($cy + $hh))
}

function Get-FocusEdgeHits([OpenCvSharp.Mat]$frame, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
    $cx = [int](($x0 + $x1) / 2); $cy = [int](($y0 + $y1) / 2)
    $probeLen = [Math]::Max(2, [int]([Math]::Max($x1 - $x0, $y1 - $y0) * 0.06))
    $lines = @(
        $frame.SubMat($y0, $y0 + $probeLen, $cx, $cx + 1)
        $frame.SubMat($y1 - $probeLen, $y1, $cx, $cx + 1)
        $frame.SubMat($cy, $cy + 1, $x0, $x0 + $probeLen)
        $frame.SubMat($cy, $cy + 1, $x1 - $probeLen, $x1)
    )
    $hits = [int[]]::new(4)
    for ($i = 0; $i -lt 4; $i++) {
        $hsv = [OpenCvSharp.Mat]::new()
        [OpenCvSharp.Cv2]::CvtColor($lines[$i], $hsv, [OpenCvSharp.ColorConversionCodes]::BGR2HSV)
        $mask = [OpenCvSharp.Mat]::new()
        [OpenCvSharp.Cv2]::InRange($hsv, $script:FOCUS_LOWER, $script:FOCUS_UPPER, $mask)
        $hits[$i] = [OpenCvSharp.Cv2]::CountNonZero($mask)
        $hsv.Dispose()
        $mask.Dispose()
        $lines[$i].Dispose()
    }

    return $hits
}

function Is-Focused([int[]]$hits) {
    return ($hits | Where-Object { $_ -gt 0 }).Count -ge 3
}

function Get-GridCells([OpenCvSharp.Mat]$frame) {
    $h = $frame.Rows
    $w = $frame.Cols
    $slotW = [int](2 * $script:SLOT_HALF_W * $w)
    $slotH = [int](2 * $script:SLOT_HALF_H * $h)
    $yLo = [int]($slotH * 0.70)
    $yHi = [int]($slotH * 0.82)
    $xLo = [int]($slotW * 0.78)
    $xHi = [int]($slotW * 0.98)
    $cells = [object[]]::new(4)
    $focused = $null
    for ($col = 0; $col -lt 4; $col++) {
        $colArr = [object[]]::new(3)
        for ($row = 0; $row -lt 3; $row++) {
            $s = Get-ScaledSlot $h $w $col $row
            $x0 = $s[0]
            $y0 = $s[1]
            $x1 = $s[2]
            $y1 = $s[3]
            $bgr = $frame.SubMat($y0, $y1, $x0, $x1)
            $gray = [OpenCvSharp.Mat]::new()
            [OpenCvSharp.Cv2]::CvtColor($bgr, $gray, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)
            $yBgr = $frame.SubMat($y0 + $yLo, $y0 + $yHi, $x0 + $xLo, $x0 + $xHi)
            $colArr[$row] = [PSCustomObject]@{ Bgr = $bgr; Gray = $gray; YellowBgr = $yBgr }
            $hits = Get-FocusEdgeHits $frame $x0 $y0 $x1 $y1
            $isFoc = Is-Focused $hits
            if (Is-DebugEnabled) {
                Log-Debug "slot c${col}r${row} slot=$($x1-$x0)x$($y1-$y0) hits=$($hits -join ',')$(if($isFoc){' <- FOCUS'})"
            }
            if ($isFoc -and $null -eq $focused) {
                $focused = @($col, $row) 
            }
        }

        $cells[$col] = $colArr
    }

    return [PSCustomObject]@{ Cells = $cells; Focused = $focused }
}

function Is-BrandNew([PSCustomObject]$cell) {
    $hsv = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::CvtColor($cell.YellowBgr, $hsv, [OpenCvSharp.ColorConversionCodes]::BGR2HSV)
    $mask = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::InRange($hsv, $script:YELLOW_LOWER, $script:YELLOW_UPPER, $mask)
    $cnt = [OpenCvSharp.Cv2]::CountNonZero($mask)
    $hsv.Dispose()
    $mask.Dispose()
    return $cnt -gt 0
}

function Slice-Grid([OpenCvSharp.Mat]$frame) {
    $grid = Get-GridCells $frame
    if ($null -eq $grid.Focused) {
        Log-Warning 'No focused slot detected; per-slot edge hits (T,B,L,R):'
        $h = $frame.Rows; $w = $frame.Cols
        for ($c = 0; $c -lt 4; $c++) {
            for ($r = 0; $r -lt 3; $r++) {
                $s = Get-ScaledSlot $h $w $c $r
                $hits = Get-FocusEdgeHits $frame $s[0] $s[1] $s[2] $s[3]
                Log-Warning "  c${c}r${r} hits=$($hits -join ',') (focused=$(Is-Focused $hits))"
            }
        }

        Ensure-DumpDir
        $p = Join-Path $script:_dumpDir "no_focus_$([int][DateTimeOffset]::Now.ToUnixTimeSeconds()).png"
        [void][OpenCvSharp.Cv2]::ImWrite($p, $frame)
        Log-Warning "Frame saved to $(Split-Path $p -Leaf)"
        Log-Error 'Stopping'
        exit 1
    }

    return [PSCustomObject]@{
        Frame   = $frame
        Cells   = $grid.Cells
        Focused = $grid.Focused
    }
}

# ============================================================================
# Navigation
# ============================================================================
function Move-Cursor($from, $to) {
    $dr = [int]$to[1] - [int]$from[1]
    Repeat-Key $(if ($dr -gt 0) {
            'down' 
        } else {
            'up' 
        }) ([Math]::Abs($dr))
    $dc = [int]$to[0] - [int]$from[0]
    Repeat-Key $(if ($dc -gt 0) {
            'right' 
        } else {
            'left' 
        }) ([Math]::Abs($dc))
}

function Is-EdgeEmpty([OpenCvSharp.Mat]$gray, [string]$side) {
    $h = $gray.Rows; $w = $gray.Cols
    $ey0 = [int](($script:CENTER_Y_R0 - $script:SLOT_HALF_H * 0.90) * $h)
    $ey1 = [int](($script:CENTER_Y_R0 + $script:SLOT_HALF_H * 0.90) * $h)
    $ew = [int]($w * $script:EDGE_WIDTH_FRAC)
    if ($side -eq 'left') {
        $strip = $gray.SubMat($ey0, $ey1, 0, $ew)
    } else {
        $strip = $gray.SubMat($ey0, $ey1, $w - $ew, $w)
    }

    $mean = [OpenCvSharp.Scalar]::new(0); $stddev = [OpenCvSharp.Scalar]::new(0)
    [OpenCvSharp.Cv2]::MeanStdDev($strip, [ref]$mean, [ref]$stddev)
    $empty = $stddev.Val0 -lt $script:EDGE_STDDEV_THRESHOLD
    if (Is-DebugEnabled) {
        Log-Debug "Is-EdgeEmpty: side=$side stddev=$([Math]::Round($stddev.Val0, 1)) threshold=$($script:EDGE_STDDEV_THRESHOLD) empty=$empty"
    }
    $strip.Dispose()
    return $empty
}

function Find-TemplateColumns([OpenCvSharp.Mat]$gray, [string]$template) {
    $w = $gray.Cols; $h = $gray.Rows
    $tmpl = Get-ScaledTemplate $template $w
    $tw = $tmpl.Cols
    $cropX = [int](($script:CENTER_X_C0 - $script:SLOT_HALF_W) * $w)
    $cropY = [int](($script:CENTER_Y_R0 - $script:SLOT_HALF_H) * $h)
    $cropR = [int](0.95 * $w)
    $cropB = [int](0.90 * $h)
    $roi = $gray.SubMat($cropY, $cropB, $cropX, $cropR)
    $res = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::MatchTemplate($roi, $tmpl, $res, [OpenCvSharp.TemplateMatchModes]::CCoeffNormed)
    $mask = [OpenCvSharp.Mat]::new()
    [void][OpenCvSharp.Cv2]::Threshold($res, $mask, (Get-Threshold $template), 1.0, [OpenCvSharp.ThresholdTypes]::Binary)
    $mask8 = [OpenCvSharp.Mat]::new()
    $mask.ConvertTo($mask8, [OpenCvSharp.MatType]::CV_8UC1, 255)
    $locs = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::FindNonZero($mask8, $locs)
    $rawHits = [System.Collections.Generic.List[double]]::new()
    if ($locs.Empty()) {
        $count = 0
    } else {
        $count = $locs.Rows
    }

    for ($i = 0; $i -lt $count; $i++) {
        $offset = $i * 8
        $px = [System.Runtime.InteropServices.Marshal]::ReadInt32($locs.Data, $offset)
        $cx = ($px + $tw / 2.0 + $cropX) / $w
        $rawHits.Add([double]$cx)
    }

    $roi.Dispose()
    $res.Dispose()
    $mask.Dispose()
    $mask8.Dispose()
    $locs.Dispose()

    $mergeWidth = $tw / [double]$w
    $hits = [System.Collections.Generic.List[double]]::new()
    foreach ($cx in @($rawHits | Sort-Object)) {
        if ($hits.Count -eq 0 -or [Math]::Abs($cx - $hits[$hits.Count - 1]) -ge $mergeWidth) {
            $hits.Add([double]$cx)
        }
    }

    $sorted = @($hits)
    if (Is-DebugEnabled) {
        Log-Debug "Find-TemplateColumns: template=$template frame=${w}x$h tmpl=${tw}x$($tmpl.Rows) raw_count=$count merged=$($sorted.Count) xfracs=[$($sorted.ForEach({ '{0:F4}' -f $_ }) -join ', ')]"
    }
    return $sorted
}

function Get-TemplateColumn([double]$xFrac) {
    return [int][Math]::Round(($xFrac - $script:CENTER_X_C0) / $script:COL_X_STEP)
}

function Analyze-Frame([OpenCvSharp.Mat]$frame, [string]$template, [string]$edgeSide = $null) {
    $gray = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::CvtColor($frame, $gray, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)
    $templateCols = Find-TemplateColumns $gray $template
    if ($null -eq $edgeSide -or $edgeSide -eq 'left') {
        $isFirst = Is-EdgeEmpty $gray 'left' 
    } else {
        $isFirst = $null 
    } 
    if ($null -eq $edgeSide -or $edgeSide -eq 'right') {
        $isLast = Is-EdgeEmpty $gray 'right' 
    } else {
        $isLast = $null 
    }
    $gray.Dispose()
    return [PSCustomObject]@{ TemplateCols = $templateCols; IsFirst = $isFirst; IsLast = $isLast }
}

function Scroll-LeftTo([string]$template) {
    Log-Info 'scanning left'
    $lefts = 0

    while ($true) {
        $frame = Capture-Frame
        $r = Analyze-Frame $frame $template 'left'
        $frame.Dispose()
        Log-Debug "left scan: matches=$($r.TemplateCols.Count) first_page=$($r.IsFirst) lefts=$lefts"

        if ($r.TemplateCols.Count -gt 0) {
            $col = Get-TemplateColumn $r.TemplateCols[0]

            if ($col -gt 0) {
                Log-Info "match at c$col, right $col"
                Repeat-Key 'right' $col
                return 0
            }

            if ($r.IsFirst) {
                Log-Info 'match at c0, first page'
                return 0
            }
        } else {
            if ($r.IsFirst) {
                Log-Info "first page, no match (lefts=$lefts)"
                return $lefts
            }
        }

        Press-Key 'left'
        $lefts++
    }
}

function Scroll-RightTo([string]$template) {
    Log-Info 'scanning right'

    while ($true) {
        $frame = Capture-Frame
        $r = Analyze-Frame $frame $template 'right'
        Log-Debug "right scan: matches=$($r.TemplateCols.Count) last_page=$($r.IsLast)"

        if ($r.TemplateCols.Count -gt 0) {
            $col = Get-TemplateColumn $r.TemplateCols[0]
            if ($col -gt 0) {
                $frame.Dispose()
                Repeat-Key 'right' $col
                Log-Info 'match at c0'
                return @{ Frame = $null }
            }

            Log-Info 'match at c0'
            return @{ Frame = $frame }
        }

        $frame.Dispose()

        if ($r.IsLast) {
            Log-Info 'last page, no match found'
            return $null
        }

        Repeat-Key 'right' 4
    }
}

function Scroll-To([string]$template) {
    Log-Info "scroll_to template=$template"
    $lefts = Scroll-LeftTo $template

    if ($lefts -eq 0) {
        return 0
    }

    Log-Info "right $lefts to return"
    Repeat-Key 'right' $lefts
    return Scroll-RightTo $template
}

# ============================================================================
# Purge
# ============================================================================
function Is-BrandNewAllowed([bool]$isNew, $brandNewFilter) {
    return $null -eq $brandNewFilter -or $isNew -eq [bool]$brandNewFilter
}

function Find-PurgeCandidate($cells, [int]$frameW, [string]$template, $marker, $brandNewFilter, $focused) {
    $candidate = $null
    $focusedIsCandidate = $false
    $debug = Is-DebugEnabled
    for ($c = 0; $c -lt 4; $c++) {
        for ($r = 0; $r -lt 3; $r++) {
            $cell = $cells[$c][$r]
            $match = Match-Template $cell.Gray $template $frameW
            $markerResult = $null
            $new = $null
            if ($match.Matched) {
                if ($null -eq $marker) {
                    $markerMatches = $true
                } else {
                    $markerResult = Match-Template $cell.Gray $marker $frameW
                    $markerMatches = $markerResult.Matched
                }
                if ($null -eq $brandNewFilter) {
                    $brandNewMatches = $true
                } else {
                    $new = Is-BrandNew $cell
                    $brandNewMatches = Is-BrandNewAllowed $new $brandNewFilter
                }
                $isCandidate = $markerMatches -and $brandNewMatches

                if ($debug) {
                    if ($null -eq $new) {
                        $newLabel = 'n/a' 
                    } else {
                        $newLabel = $new.ToString() 
                    }
                    if ($null -eq $markerResult) {
                        $markerLabel = 'n/a'
                    } else {
                        $markerLabel = Format-TemplateDetails @([pscustomobject]@{
                                Name    = $marker
                                Score   = [double]$markerResult.Score
                                Matched = [bool]$markerResult.Matched
                            })
                    }
                    $templateLabel = Format-TemplateDetails @([pscustomobject]@{
                            Name    = $template
                            Score   = [double]$match.Score
                            Matched = [bool]$match.Matched
                        })
                    Log-Debug "slot c${c}r${r} template=$templateLabel marker=$markerLabel brand_new=$newLabel candidate=$isCandidate"
                }

                if ($isCandidate) {
                    if ($focused -and [int]$focused[0] -eq $c -and [int]$focused[1] -eq $r) {
                        $candidate = @($c, $r)
                        $focusedIsCandidate = $true
                    } elseif ($null -eq $candidate) {
                        $candidate = @($c, $r)
                    }
                }
            } elseif ($debug) {
                $templateLabel = Format-TemplateDetails @([pscustomobject]@{
                        Name    = $template
                        Score   = [double]$match.Score
                        Matched = [bool]$match.Matched
                    })
                Log-Debug "slot c${c}r${r} template=$templateLabel marker=n/a brand_new=n/a candidate=False"
            }
        }
    }

    return [PSCustomObject]@{
        Candidate          = $candidate
        FocusedIsCandidate = $focusedIsCandidate
    }
}

function Invoke-PurgeSequence {
    Press-Key 'enter'
    Wait-ForRefresh
    Repeat-Key 'down' 4
    Press-Key 'enter'
    Wait-ForRefresh
    Press-Key 'down'
    Press-Key 'enter'
}

function Invoke-Purge([string]$template, $marker = $null, $brandNewFilter = $null) {
    $deletions = 0
    $iterIdx = 0
    Log-Info "purge template=$template marker=$(Format-Marker $marker) brand_new=$(Format-BrandNew $brandNewFilter)"
    while ($true) {
        $result = Scroll-RightTo $template
        if ($null -eq $result) {
            Log-Info "No more matches; done ($deletions deletions)"
            return
        }

        if ($result.Frame) {
            $frame = $result.Frame
        } else {
            $frame = Capture-Frame
        }
        
        $slices = Slice-Grid $frame
        if ($script:_dumpToDisk) {
            Save-DumpCells $slices.Cells "iter$iterIdx" 
        }
        $scan = Find-PurgeCandidate $slices.Cells $slices.Frame.Cols $template $marker $brandNewFilter $slices.Focused

        if ($null -eq $scan.Candidate) {
            $gray = [OpenCvSharp.Mat]::new()
            [OpenCvSharp.Cv2]::CvtColor($slices.Frame, $gray, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)
            $isLast = Is-EdgeEmpty $gray 'right'
            $gray.Dispose()
            Dispose-GridCells $slices.Cells
            $slices.Frame.Dispose()

            if ($isLast) {
                Log-Info "Last page, no more candidates; done ($deletions deletions)"
                return
            }

            Log-Info 'no candidate this view; right 4'
            Repeat-Key 'right' 4
            continue
        }

        if ($scan.FocusedIsCandidate) {
            Log-Info "focused candidate at c$($scan.Candidate[0])r$($scan.Candidate[1])"
        } else {
            Log-Info "candidate at c$($scan.Candidate[0])r$($scan.Candidate[1])"
            Move-Cursor $slices.Focused $scan.Candidate
        }
        Invoke-PurgeSequence
        $deletions++
        Log-Info "deleted ($deletions)"
        $iterIdx++
        Dispose-GridCells $slices.Cells
        $slices.Frame.Dispose()
    }
}

# ============================================================================
# Snap
# ============================================================================
function Invoke-Snap {
    Ensure-DumpDir
    $frame = Capture-Frame -wait 0
    [void][OpenCvSharp.Cv2]::ImWrite((Join-Path $script:_dumpDir 'frame.png'), $frame)
    $grid = Get-GridCells $frame
    for ($c = 0; $c -lt 4; $c++) {
        for ($r = 0; $r -lt 3; $r++) {
            $cell = $grid.Cells[$c][$r]
            [void][OpenCvSharp.Cv2]::ImWrite((Join-Path $script:_dumpDir "c${c}r${r}_slot.png"), $cell.Bgr)
            [void][OpenCvSharp.Cv2]::ImWrite((Join-Path $script:_dumpDir "c${c}r${r}_brand_new.png"), $cell.YellowBgr)
        }
    }

    Log-Info "wrote frame + 24 slot crops to $script:_dumpDir"
    Dispose-GridCells $grid.Cells
    $frame.Dispose()
}

# ============================================================================
# Detect
# ============================================================================
function Invoke-Detect([hashtable]$screenMap) {
    try {
        $frame = Capture-Frame -wait $script:POLL_INTERVAL
    } catch {
        Log-Error "$_ -- pausing 1s and retrying"
        Start-Sleep -Seconds 1
        return
    }

    $g = [OpenCvSharp.Mat]::new()
    [OpenCvSharp.Cv2]::CvtColor($frame, $g, [OpenCvSharp.ColorConversionCodes]::BGR2GRAY)

    $matched = $null
    $matchDetails = $null
    foreach ($n in $screenMap.Keys) {
        $r = Match-Template $g $n
        if ($r.Matched) {
            $matched = $n
            $matchDetails = @([pscustomobject]@{
                    Name    = $n
                    Score   = [double]$r.Score
                    Matched = $true
                })
            break
        }
    }

    $g.Dispose()
    $frame.Dispose()

    if ($matched) {
        $now = [DateTime]::Now
        if ($null -eq $script:_lastDetectMatchAt) {
            $timing = 'first match'
        } else {
            $timing = 'since last match {0:F1}s' -f ($now - $script:_lastDetectMatchAt).TotalSeconds
        }
        $script:_lastDetectMatchAt = $now

        $key = $screenMap[$matched]
        Log-Info "screen=$matched verified ($(Format-TemplateDetails $matchDetails), $timing) -> press $key"
        Press-Key $key
    }
}

# ============================================================================
# Workflow validation
# ============================================================================
function Read-TemplateExpression([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [System.Collections.IDictionary])) {
        Log-Error "$actionName requires a mapping with template"
        exit 1
    }

    if ($actionValue.ContainsKey('match')) {
        Log-Error "$actionName uses template, not match"
        exit 1
    }

    if (-not $actionValue.ContainsKey('template')) {
        Log-Error "$actionName requires template"
        exit 1
    }

    Validate-TemplateExpression $actionName $actionValue['template']
    return $actionValue['template']
}

function Read-Template([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [string])) {
        Log-Error "$actionName requires a single template name"
        exit 1
    }

    return $actionValue.ToString()
}

function Read-MappingTemplate([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [System.Collections.IDictionary])) {
        Log-Error "$actionName requires a mapping with template"
        exit 1
    }

    if ($actionValue.ContainsKey('match')) {
        Log-Error "$actionName uses template, not match"
        exit 1
    }

    if (-not $actionValue.ContainsKey('template')) {
        Log-Error "$actionName requires template"
        exit 1
    }

    if (-not ($actionValue['template'] -is [string])) {
        Log-Error "$actionName template must be a single template name"
        exit 1
    }

    return $actionValue['template'].ToString()
}

function Read-Marker([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [System.Collections.IDictionary]) -or -not $actionValue.ContainsKey('marker') -or $null -eq $actionValue['marker']) {
        return $null
    }

    if (-not ($actionValue['marker'] -is [string])) {
        Log-Error "$actionName marker must be a single template name"
        exit 1
    }

    return $actionValue['marker'].ToString()
}

function Read-BrandNew([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [System.Collections.IDictionary]) -or -not $actionValue.ContainsKey('brand_new') -or $null -eq $actionValue['brand_new']) {
        Log-Error "$actionName requires brand_new: true, false, or bypass"
        exit 1
    }

    $brandNew = $actionValue['brand_new']
    if ($brandNew -is [bool]) {
        return [bool]$brandNew
    }

    if ($brandNew.ToString() -eq 'True') {
        return $true
    }

    if ($brandNew.ToString() -eq 'False') {
        return $false
    }

    if ($brandNew -is [string] -and $brandNew.ToLowerInvariant() -eq 'bypass') {
        return $null
    }

    Log-Error "$actionName brand_new must be true, false, or bypass"
    exit 1
}

function Format-BrandNew($brandNewFilter) {
    if ($null -eq $brandNewFilter) {
        return 'bypass' 
    }
    return $brandNewFilter.ToString().ToLowerInvariant()
}

function Format-Marker($marker) {
    if ($marker) {
        return $marker 
    }
    return 'bypass'
}

function Validate-TemplateExpression([string]$actionName, $expr) {
    if ($expr -is [string]) {
        if ($expr -eq '') {
            Log-Error "$actionName template must not be empty"
            exit 1
        }
        return
    }

    if ($expr -is [System.Collections.IList]) {
        Log-Error "$actionName template lists must be under all or any"
        exit 1
    }

    if (-not ($expr -is [System.Collections.IDictionary])) {
        Log-Error "$actionName template must be a template name or an all/any expression"
        exit 1
    }

    $keys = @($expr.Keys)
    if ($keys.Count -ne 1 -or ($keys[0].ToString() -ne 'all' -and $keys[0].ToString() -ne 'any')) {
        Log-Error "$actionName template expression must contain exactly one key: all or any"
        exit 1
    }

    $op = $keys[0].ToString()
    $items = @($expr[$op])
    if ($items.Count -eq 0 -or $expr[$op] -is [string]) {
        Log-Error "$actionName template $op expression must be a non-empty list"
        exit 1
    }

    foreach ($item in $items) {
        Validate-TemplateExpression $actionName $item
    }
}

function Validate-Number([string]$actionName, $value, [string]$field = 'value', [bool]$integer = $false, [bool]$allowEmpty = $false) {
    if ($null -eq $value -or $value.ToString() -eq '') {
        if ($allowEmpty) {
            return 
        }
        Log-Error "$actionName requires $field"
        exit 1
    }

    try {
        if ($integer) {
            $parsed = [int]$value
        } else {
            $parsed = [double]$value
        }
    } catch {
        if ($integer) {
            $kind = 'integer' 
        } else {
            $kind = 'number' 
        }
        Log-Error "$actionName $field must be a $kind"
        exit 1
    }

    if ($parsed -lt 0) {
        Log-Error "$actionName $field must be >= 0"
        exit 1
    }
}

function Read-Repeat([string]$actionName, $actionValue) {
    if (-not ($actionValue -is [System.Collections.IDictionary])) {
        Log-Error "$actionName requires key and times"
        exit 1
    }

    if (-not $actionValue.ContainsKey('key') -or $null -eq $actionValue['key'] -or $actionValue['key'].ToString() -eq '') {
        Log-Error "$actionName requires key"
        exit 1
    }

    if (-not $actionValue.ContainsKey('times') -or $null -eq $actionValue['times']) {
        Log-Error "$actionName requires times"
        exit 1
    }

    try {
        $times = [int]$actionValue['times']
    } catch {
        Log-Error "$actionName times must be an integer"
        exit 1
    }

    if ($times -lt 0) {
        Log-Error "$actionName times must be >= 0"
        exit 1
    }

    return [pscustomobject]@{
        Key   = $actionValue['key'].ToString()
        Times = $times
    }
}

function Validate-Step($step, [int]$index) {
    if (-not ($step -is [System.Collections.IDictionary]) -or @($step.Keys).Count -ne 1) {
        Log-Error "step $index must be a single action mapping"
        exit 1
    }

    $actionName = ($step.Keys | Select-Object -First 1).ToString()
    $actionValue = $step[$actionName]

    switch ($actionName) {
        'press' {
            if ($null -eq $actionValue -or $actionValue.ToString() -eq '') {
                Log-Error "step $index press requires a key"
                exit 1
            }
        }
        'wait' {
            Validate-Number $actionName $actionValue -allowEmpty $true
        }
        'repeat' {
            [void](Read-Repeat $actionName $actionValue)
        }
        'countdown' {
            Validate-Number $actionName $actionValue -integer $true -allowEmpty $true
        }
        'wait_on' {
            [void](Read-TemplateExpression $actionName $actionValue)
            if ($actionValue.ContainsKey('timeout') -and $null -ne $actionValue['timeout']) {
                Validate-Number $actionName $actionValue['timeout'] -field 'timeout'
            }
            if ($actionValue.ContainsKey('on_miss') -and ($null -eq $actionValue['on_miss'] -or $actionValue['on_miss'].ToString() -eq '')) {
                Log-Error 'wait_on on_miss must be a key'
                exit 1
            }
        }
        'scroll_to' {
            [void](Read-Template $actionName $actionValue)
        }
        'purge' {
            [void](Read-MappingTemplate $actionName $actionValue)
            [void](Read-Marker $actionName $actionValue)
            [void](Read-BrandNew $actionName $actionValue)
        }
        'snap' {
            if ($null -ne $actionValue -and $actionValue.ToString() -ne '') {
                Log-Error 'snap does not accept arguments'
                exit 1
            }
        }
        'detect' {
            if (-not ($actionValue -is [System.Collections.IDictionary]) -or @($actionValue.Keys).Count -eq 0) {
                Log-Error 'detect requires one or more template-to-key mappings'
                exit 1
            }
            foreach ($kv in $actionValue.GetEnumerator()) {
                if ($null -eq $kv.Key -or $kv.Key.ToString() -eq '' -or $null -eq $kv.Value -or $kv.Value.ToString() -eq '') {
                    Log-Error 'detect mappings must be template: key'
                    exit 1
                }
            }
        }
        default {
            Log-Error "Unknown action: $actionName"
            exit 1
        }
    }
}

function Validate-Workflow($workflow) {
    if (-not ($workflow -is [System.Collections.IDictionary])) {
        Log-Error 'workflow must be a mapping'
        exit 1
    }

    if (-not $workflow.ContainsKey('steps') -or -not ($workflow['steps'] -is [System.Collections.IList]) -or $workflow['steps'].Count -eq 0) {
        Log-Error 'workflow requires non-empty steps'
        exit 1
    }

    if ($workflow.ContainsKey('loop') -and $workflow['loop'].ToString() -ne 'True' -and $workflow['loop'].ToString() -ne 'False') {
        Validate-Number 'workflow' $workflow['loop'] -field 'loop' -integer $true
    }

    if ($workflow.ContainsKey('focus_mode') -and $workflow['focus_mode'].ToString() -ne 'exit' -and $workflow['focus_mode'].ToString() -ne 'pause') {
        Log-Error 'workflow focus_mode must be exit or pause'
        exit 1
    }

    foreach ($field in @('await_focus', 'report_cycle_time')) {
        if ($workflow.ContainsKey($field) -and $workflow[$field].ToString() -ne 'True' -and $workflow[$field].ToString() -ne 'False') {
            Log-Error "workflow $field must be true or false"
            exit 1
        }
    }

    if ($workflow.ContainsKey('hold')) {
        $hold = $workflow['hold']
        if (-not ($hold -is [System.Collections.IDictionary]) -or -not $hold.ContainsKey('key') -or $null -eq $hold['key'] -or $hold['key'].ToString() -eq '') {
            Log-Error 'workflow hold requires key'
            exit 1
        }
        if ($hold.ContainsKey('release_on_lose_focus') -and $hold['release_on_lose_focus'].ToString() -ne 'True' -and $hold['release_on_lose_focus'].ToString() -ne 'False') {
            Log-Error 'workflow hold release_on_lose_focus must be true or false'
            exit 1
        }
    }

    for ($i = 0; $i -lt $workflow['steps'].Count; $i++) {
        Validate-Step $workflow['steps'][$i] ($i + 1)
    }

    Log-Info 'Validated workflow'
}

# ============================================================================
# Step runner
# ============================================================================
function Invoke-Step($step) {
    $actionName = ($step.Keys | Select-Object -First 1).ToString()
    $actionValue = $step[$actionName]
    $script:_currentStep = $actionName

    switch ($actionName) {
        'press' {
            Press-Key $actionValue.ToString()
        }
        'wait' {
            if ($null -eq $actionValue -or $actionValue.ToString() -eq '') {
                Wait-ForRefresh
            } else {
                Wait-ForRefresh ([double]$actionValue)
            }
        }
        'repeat' {
            Repeat-Key $actionValue['key'].ToString() ([int]$actionValue['times'])
        }
        'countdown' {
            if ($null -eq $actionValue -or $actionValue.ToString() -eq '') {
                Wait-Countdown 3 'Waiting'
            } else {
                Wait-Countdown ([int]$actionValue) 'Waiting'
            }
        }
        'wait_on' {
            $templateExpr = $actionValue['template']
            if ($actionValue['timeout']) {
                $tout = [double]$actionValue['timeout']
            } else {
                $tout = $script:VERIFY_TIMEOUT
            }
            $onMiss = $actionValue['on_miss']
            if ($onMiss) {
                Wait-ForTemplate $templateExpr -timeout $tout -onMiss $onMiss.ToString()
            } else {
                Wait-ForTemplate $templateExpr -timeout $tout
            }
        }
        'scroll_to' {
            $result = Scroll-To $actionValue.ToString()
            if ($null -eq $result) {
                Log-Info 'No matches found; stopping'
                exit 0
            }
        }
        'purge' {
            $brandNew = $actionValue['brand_new']
            if ($brandNew.ToString() -eq 'True') {
                $brandNewFilter = $true
            } elseif ($brandNew.ToString() -eq 'False') {
                $brandNewFilter = $false
            } else {
                $brandNewFilter = $null
            }
            if ($actionValue.ContainsKey('marker') -and $null -ne $actionValue['marker']) {
                $marker = $actionValue['marker'].ToString()
            } else {
                $marker = $null
            }
            Invoke-Purge `
                $actionValue['template'].ToString() `
                $marker `
                $brandNewFilter
        }
        'snap' {
            Invoke-Snap
        }
        'detect' {
            $screenMap = @{}
            foreach ($kv in $actionValue.GetEnumerator()) {
                $screenMap[$kv.Key.ToString()] = $kv.Value.ToString()
            }

            Invoke-Detect $screenMap
        }
    }

    $script:_currentStep = $null
}

# ============================================================================
# Workflow runner
# ============================================================================
function Invoke-Workflow($workflow) {
    if ($workflow.ContainsKey('loop')) {
        $loopVal = $workflow['loop']
    } else {
        $loopVal = $false
    }

    $lv = $loopVal.ToString()
    if ($lv -eq 'True') {
        $maxCycles = -1
    } elseif ($lv -eq 'False') {
        $maxCycles = 1
    } else {
        $maxCycles = [int]$lv
    }

    if ($maxCycles -eq 0) {
        $maxCycles = 1 
    }

    if ($workflow.ContainsKey('focus_mode')) {
        $focusMode = $workflow['focus_mode'].ToString()
    } else {
        $focusMode = 'exit'
    }

    # Hold: parsed from workflow-level 'hold' property
    $script:_holdKeys = @{}
    if ($workflow.ContainsKey('hold')) {
        $h = $workflow['hold']
        $k = $h['key'].ToString().ToUpper()
        if ($h.ContainsKey('release_on_lose_focus')) {
            $release = $h['release_on_lose_focus'].ToString() -eq 'True'
        } else {
            $release = $true
        }

        $script:_holdKeys[$k] = @{
            Held               = $false
            ReleaseOnLoseFocus = $release
        }

        Log-Info "Hold: $k (release_on_lose_focus=$release)"
    }

    if ($workflow.ContainsKey('report_cycle_time')) {
        $reportCycleTime = $workflow['report_cycle_time'].ToString() -eq 'True'
    } else {
        $reportCycleTime = $false
    }

    $steps = $workflow['steps']
    $cycle = 0

    try {
        do {
            $cycle++
            if ($maxCycles -gt 0) {
                Log-Info "cycle $cycle/$maxCycles starting" 
            }
            $cycleStart = [DateTime]::Now

            foreach ($step in $steps) {
                # Focus guard
                if (-not (Is-WindowFocused)) {
                    if ($focusMode -eq 'exit') {
                        Log-Error 'Lost focus, stopping'
                        exit 1
                    }
                    # pause mode: release held keys that have release_on_lose_focus
                    foreach ($k in @($script:_holdKeys.Keys)) {
                        $h = $script:_holdKeys[$k]
                        if ($h.Held -and $h.ReleaseOnLoseFocus) {
                            Release-Key $k
                            $h.Held = $false
                        }
                    }

                    while (-not (Is-WindowFocused)) {
                        Wait-PollTick 
                    }
                }

                # Re-hold keys after refocus or if dropped
                foreach ($k in @($script:_holdKeys.Keys)) {
                    $h = $script:_holdKeys[$k]
                    if (-not $h.Held) {
                        Hold-Key $k
                        $h.Held = $true
                    } elseif (-not (Is-KeyHeld $k)) {
                        Log-Debug "$k dropped, re-pressing"
                        Hold-Key $k
                    }
                }

                Invoke-Step $step
            }

            if ($reportCycleTime) {
                $elapsed = ([DateTime]::Now - $cycleStart).TotalSeconds
                if ($maxCycles -gt 0) {
                    Log-Info "cycle $cycle/$maxCycles completed in $([Math]::Round($elapsed, 1))s"
                } else {
                    Log-Info "cycle $cycle completed in $([Math]::Round($elapsed, 1))s"
                }

                Log-Info '----------------------------------------'
            }
        } while ($maxCycles -lt 0 -or $cycle -lt $maxCycles)
    } finally {
        foreach ($k in @($script:_holdKeys.Keys)) {
            if ($script:_holdKeys[$k].Held) {
                Release-Key $k
            }
        }

    }
}

# ============================================================================
# Main dispatcher
# ============================================================================
if (-not $Action) {
    Write-Host 'Forza Horizon 6 automation CLI'
    Write-Host ''
    Write-Host 'Usage:'
    Write-Host '  .\cli.ps1 <name|path.yaml> [-Dump] [-Verbose]'
    exit 0
}

# Workflow
$yamlPath = if ($Action -like '*.yaml' -or $Action -like '*.yml') {
    $Action 
} else {
    Join-Path $PSScriptRoot "workflows\$Action.yaml" 
}
if (-not (Test-Path $yamlPath)) {
    Write-Error "Workflow not found: $yamlPath"
    exit 1
}
$workflow = Read-Yaml $yamlPath

$script:_dumpToDisk = [bool]$Dump
if ($VerbosePreference -eq 'Continue') {
    $script:_logLevel = 'DEBUG'
} else {
    $script:_logLevel = 'INFO'
}

if ($script:_dumpToDisk) {
    Ensure-DumpDir
    $script:_logFile = Join-Path $script:_dumpDir 'cli.log'
}

Validate-Workflow $workflow

Log-Info '=== workflow starting ==='

$hwnd = Get-GameWindow
if ($hwnd -eq [IntPtr]::Zero) {
    Log-Error "Window '$($script:WINDOW_TITLE)' not found"
    exit 1
}
Log-Info "Found window: $($script:WINDOW_TITLE)"

$waitFocus = $workflow.ContainsKey('await_focus') -and $workflow['await_focus'].ToString() -eq 'True'
if ($waitFocus) {
    Log-Info 'Waiting for game window focus...'
    while (-not (Is-WindowFocused)) {
        Wait-PollTick 
    }
    Log-Info 'Game window focused'
}

Wait-Countdown 3 'Starting'

$frame = Capture-Frame -wait 0
Log-Info "Captured frame $($frame.Cols)x$($frame.Rows)"
$frame.Dispose()

Invoke-Workflow $workflow
