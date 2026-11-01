'use strict';
/*
 * Windows UI Automation grounding. Lists clickable controls of the foreground
 * window with exact pixel rectangles, so the agent can click by name instead of
 * guessing coordinates from a screenshot. Uses PowerShell + UIAutomationClient.
 */
const { runPowerShell } = require('./powershell');

const LIST_SCRIPT = `
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name D -Namespace U2 | Out-Null
[U2.D]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$hwnd = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();' -Name W -Namespace U -PassThru
$fg = $hwnd::GetForegroundWindow()
$win = [System.Windows.Automation.AutomationElement]::FromHandle($fg)
$types = 'Button','MenuItem','Hyperlink','TabItem','CheckBox','RadioButton','Edit','ComboBox','ListItem','TreeItem','SplitButton','Document'
$cond = New-Object System.Windows.Automation.OrCondition(@($types | ForEach-Object { New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::$_ ) }))
$els = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
$out = @()
$n = 0
foreach ($e in $els) {
  if ($n -ge 150) { break }
  try {
    $c = $e.Current
    if ($c.IsOffscreen) { continue }
    $r = $c.BoundingRectangle
    if ($r.Width -lt 2 -or $r.Height -lt 2 -or [double]::IsInfinity($r.X)) { continue }
    $name = $c.Name
    if (-not $name) { $name = $c.AutomationId }
    if (-not $name) { continue }
    $out += [pscustomobject]@{ name = $name; type = $c.ControlType.ProgrammaticName.Replace('ControlType.',''); x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height }
    $n++
  } catch {}
}
@{ title = $win.Current.Name; elements = $out } | ConvertTo-Json -Depth 4 -Compress
`;

function parseElementsJson(text) {
  try {
    const j = JSON.parse(text);
    let els = j.elements || [];
    if (!Array.isArray(els)) els = [els];
    return { title: j.title || '', elements: els.filter((e) => e && e.name) };
  } catch (_) {
    return { title: '', elements: [] };
  }
}

function findElement(elements, query) {
  const q = String(query || '').toLowerCase().trim();
  if (!q) return null;
  const exact = elements.find((e) => e.name.toLowerCase() === q);
  if (exact) return exact;
  const starts = elements.find((e) => e.name.toLowerCase().startsWith(q));
  if (starts) return starts;
  return elements.find((e) => e.name.toLowerCase().includes(q)) || null;
}

async function listForegroundElements(run = runPowerShell) {
  const r = await run(LIST_SCRIPT, { timeoutMs: 12000 });
  return parseElementsJson(r.stdout);
}

// Compact text for the model. Rects are converted to the model's coordinate space by the caller.
function describeElements(elements, mapRect) {
  return elements
    .slice(0, 80)
    .map((e) => {
      const r = mapRect ? mapRect(e) : { x: e.x, y: e.y, width: e.w, height: e.h };
      return `${e.type}: "${e.name.slice(0, 60)}" at ${r.x + Math.round(r.width / 2)},${r.y + Math.round(r.height / 2)}`;
    })
    .join('\n');
}

module.exports = { listForegroundElements, parseElementsJson, findElement, describeElements, LIST_SCRIPT };
