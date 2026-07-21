param(
    [ValidateSet('Live', 'Disconnected', 'Protected', 'Unprotected', 'Blocked', 'Incomplete', 'Error')]
    [string]$PreviewState = 'Live',
    [string]$PreviewOutput
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ruleGroup = 'Switzerland VPN Kill Switch'
$scriptFolder = Split-Path -Parent $PSCommandPath
$onScript = Join-Path $scriptFolder 'Switzerland VPN ON.ps1'
$offScript = Join-Path $scriptFolder 'Switzerland VPN OFF.ps1'
$profileFile = Join-Path $scriptFolder 'VPN Profile.txt'

function Get-ConfiguredVpnName {
    if (-not (Test-Path -LiteralPath $profileFile -PathType Leaf)) {
        throw "Missing file: $profileFile"
    }

    $name = (Get-Content -LiteralPath $profileFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name.Contains("`r") -or $name.Contains("`n")) {
        throw 'VPN Profile.txt must contain exactly one non-empty Windows VPN profile name.'
    }
    return $name
}

$vpnName = Get-ConfiguredVpnName

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ManagedVpnConnection {
    try {
        return Get-VpnConnection -Name $vpnName -AllUserConnection -ErrorAction Stop
    }
    catch {
        return Get-VpnConnection -Name $vpnName -ErrorAction Stop
    }
}

if ($PreviewState -eq 'Live' -and -not (Test-Administrator)) {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', "`"$PSCommandPath`""
    )
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
    exit
}

if (-not (Test-Path -LiteralPath $onScript)) {
    [Windows.Forms.MessageBox]::Show("Missing file:`n$onScript", 'Switzerland VPN', 'OK', 'Error') | Out-Null
    exit
}

if (-not (Test-Path -LiteralPath $offScript)) {
    [Windows.Forms.MessageBox]::Show("Missing file:`n$offScript", 'Switzerland VPN', 'OK', 'Error') | Out-Null
    exit
}

[Windows.Forms.Application]::EnableVisualStyles()

$form = [Windows.Forms.Form]::new()
$form.Text = 'Switzerland VPN'
$form.ClientSize = [Drawing.Size]::new(360, 225)
$form.MinimumSize = [Drawing.Size]::new(376, 264)
$form.MaximumSize = [Drawing.Size]::new(376, 264)
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost = $true
$form.BackColor = [Drawing.Color]::FromArgb(24, 26, 31)
$form.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Font = [Drawing.Font]::new('Segoe UI', 9)
$form.ShowInTaskbar = $true

$workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = [Drawing.Point]::new(
    $workingArea.Right - $form.Width - 18,
    $workingArea.Bottom - $form.Height - 18
)

$titleLabel = [Windows.Forms.Label]::new()
$titleLabel.Text = 'SWITZERLAND VPN'
$titleLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 14)
$titleLabel.ForeColor = [Drawing.Color]::FromArgb(235, 238, 244)
$titleLabel.AutoSize = $true
$titleLabel.Location = [Drawing.Point]::new(18, 15)
$form.Controls.Add($titleLabel)

$statusDot = [Windows.Forms.Label]::new()
$statusDot.Text = 'STATUS:'
$statusDot.Font = [Drawing.Font]::new('Segoe UI Semibold', 9)
$statusDot.AutoSize = $true
$statusDot.Location = [Drawing.Point]::new(18, 56)
$form.Controls.Add($statusDot)

$statusLabel = [Windows.Forms.Label]::new()
$statusLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
$statusLabel.AutoSize = $false
$statusLabel.AutoEllipsis = $true
$statusLabel.Size = [Drawing.Size]::new(264, 22)
$statusLabel.Location = [Drawing.Point]::new(78, 55)
$form.Controls.Add($statusLabel)

$detailLabel = [Windows.Forms.Label]::new()
$detailLabel.ForeColor = [Drawing.Color]::FromArgb(170, 176, 188)
$detailLabel.AutoSize = $false
$detailLabel.AutoEllipsis = $true
$detailLabel.Size = [Drawing.Size]::new(324, 20)
$detailLabel.Location = [Drawing.Point]::new(18, 79)
$form.Controls.Add($detailLabel)

function New-WidgetButton([string]$text, [Drawing.Point]$location, [Drawing.Color]$color) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $text
    $button.Location = $location
    $button.Size = [Drawing.Size]::new(156, 42)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $color
    $button.ForeColor = [Drawing.Color]::White
    $button.Font = [Drawing.Font]::new('Segoe UI Semibold', 9)
    $button.Cursor = 'Hand'
    return $button
}

$connectButton = New-WidgetButton 'CONNECT + ARM' ([Drawing.Point]::new(18, 108)) ([Drawing.Color]::FromArgb(27, 139, 93))
$disconnectButton = New-WidgetButton 'DISCONNECT + UNLOCK' ([Drawing.Point]::new(185, 108)) ([Drawing.Color]::FromArgb(177, 63, 68))
$form.Controls.Add($connectButton)
$form.Controls.Add($disconnectButton)

$topMostCheck = [Windows.Forms.CheckBox]::new()
$topMostCheck.Text = 'Always on top'
$topMostCheck.Checked = $true
$topMostCheck.AutoSize = $true
$topMostCheck.Location = [Drawing.Point]::new(18, 164)
$topMostCheck.ForeColor = [Drawing.Color]::FromArgb(210, 214, 222)
$form.Controls.Add($topMostCheck)

$refreshButton = [Windows.Forms.Button]::new()
$refreshButton.Text = 'Refresh'
$refreshButton.Size = [Drawing.Size]::new(72, 27)
$refreshButton.Location = [Drawing.Point]::new(269, 160)
$refreshButton.FlatStyle = 'Flat'
$refreshButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(80, 85, 96)
$refreshButton.BackColor = [Drawing.Color]::FromArgb(42, 45, 53)
$refreshButton.ForeColor = [Drawing.Color]::WhiteSmoke
$form.Controls.Add($refreshButton)

$noteLabel = [Windows.Forms.Label]::new()
$noteLabel.Text = "Fail-closed protection: If the VPN drops,`ninternet remains blocked."
$noteLabel.ForeColor = [Drawing.Color]::FromArgb(137, 143, 155)
$noteLabel.Font = [Drawing.Font]::new('Segoe UI', 8)
$noteLabel.AutoSize = $false
$noteLabel.Size = [Drawing.Size]::new(324, 32)
$noteLabel.Location = [Drawing.Point]::new(18, 192)
$form.Controls.Add($noteLabel)

function Get-WidgetState {
    if ($PreviewState -ne 'Live') {
        switch ($PreviewState) {
            'Disconnected' {
                return [pscustomobject]@{ Connected = $false; KillSwitchActive = $false; KillSwitchIncomplete = $false }
            }
            'Protected' {
                return [pscustomobject]@{ Connected = $true; KillSwitchActive = $true; KillSwitchIncomplete = $false }
            }
            'Unprotected' {
                return [pscustomobject]@{ Connected = $true; KillSwitchActive = $false; KillSwitchIncomplete = $false }
            }
            'Blocked' {
                return [pscustomobject]@{ Connected = $false; KillSwitchActive = $true; KillSwitchIncomplete = $false }
            }
            'Incomplete' {
                return [pscustomobject]@{ Connected = $false; KillSwitchActive = $false; KillSwitchIncomplete = $true }
            }
            'Error' {
                throw 'Unable to read the VPN or firewall status.'
            }
        }
    }

    $vpn = Get-ManagedVpnConnection
    $killSwitchRuleCount = @(
        Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue |
            Where-Object Enabled -eq 'True'
    ).Count

    return [pscustomobject]@{
        Connected = $vpn.ConnectionStatus -eq 'Connected'
        KillSwitchActive = $killSwitchRuleCount -eq 4
        KillSwitchIncomplete = $killSwitchRuleCount -gt 0 -and $killSwitchRuleCount -ne 4
    }
}

function Update-WidgetStatus {
    try {
        $current = Get-WidgetState

        if ($current.KillSwitchIncomplete) {
            $statusDot.ForeColor = [Drawing.Color]::FromArgb(239, 75, 79)
            $statusLabel.Text = 'KILL SWITCH SETUP INCOMPLETE'
            $detailLabel.Text = 'Press CONNECT + ARM to rebuild all firewall rules.'
        }
        elseif ($current.Connected -and $current.KillSwitchActive) {
            $statusDot.ForeColor = [Drawing.Color]::FromArgb(57, 206, 136)
            $statusLabel.Text = 'CONNECTED AND PROTECTED'
            $detailLabel.Text = 'Switzerland VPN is active. The kill switch is armed.'
        }
        elseif ($current.Connected) {
            $statusDot.ForeColor = [Drawing.Color]::FromArgb(244, 178, 65)
            $statusLabel.Text = 'CONNECTED, NOT PROTECTED'
            $detailLabel.Text = 'The VPN is active without kill-switch protection.'
        }
        elseif ($current.KillSwitchActive) {
            $statusDot.ForeColor = [Drawing.Color]::FromArgb(239, 75, 79)
            $statusLabel.Text = 'VPN DOWN - INTERNET BLOCKED'
            $detailLabel.Text = 'The kill switch is active. Use DISCONNECT + UNLOCK.'
        }
        else {
            $statusDot.ForeColor = [Drawing.Color]::FromArgb(132, 139, 151)
            $statusLabel.Text = 'DISCONNECTED'
            $detailLabel.Text = 'The VPN is off. Normal internet is available.'
        }
    }
    catch {
        $statusDot.ForeColor = [Drawing.Color]::FromArgb(239, 75, 79)
        $statusLabel.Text = 'STATUS UNAVAILABLE'
        $detailLabel.Text = $_.Exception.Message
    }
}

function Invoke-WidgetAction([string]$scriptPath) {
    $connectButton.Enabled = $false
    $disconnectButton.Enabled = $false
    $refreshButton.Enabled = $false
    $form.UseWaitCursor = $true

    try {
        & $scriptPath
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Switzerland VPN',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.UseWaitCursor = $false
        $connectButton.Enabled = $true
        $disconnectButton.Enabled = $true
        $refreshButton.Enabled = $true
        Update-WidgetStatus
    }
}

$connectButton.Add_Click({ Invoke-WidgetAction $onScript })
$disconnectButton.Add_Click({ Invoke-WidgetAction $offScript })
$refreshButton.Add_Click({ Update-WidgetStatus })
$topMostCheck.Add_CheckedChanged({ $form.TopMost = $topMostCheck.Checked })

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 2000
$timer.Add_Tick({ Update-WidgetStatus })

$form.Add_Shown({
    Update-WidgetStatus
    $timer.Start()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    $timer.Stop()

    if ($PreviewState -ne 'Live') {
        return
    }

    try {
        $current = Get-WidgetState
        if ($current.KillSwitchActive) {
            $answer = [Windows.Forms.MessageBox]::Show(
                'The kill switch is still armed. Closing this widget will NOT unblock the internet. Close anyway?',
                'Switzerland VPN',
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                $timer.Start()
            }
        }
    }
    catch {
        # Allow the widget to close if status inspection itself fails.
    }
})

if ($PreviewState -ne 'Live' -and $PreviewOutput) {
    $form.TopMost = $false
    $form.ShowInTaskbar = $false
    $form.Location = [Drawing.Point]::new(-32000, -32000)
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Update-WidgetStatus
    [Windows.Forms.Application]::DoEvents()

    $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
    $bitmap.Save($PreviewOutput, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $timer.Stop()
    $form.Close()
    exit
}

[Windows.Forms.Application]::Run($form)
