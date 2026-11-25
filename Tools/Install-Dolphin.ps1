Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:cancelRequested = $false
$script:installPath = Join-Path $env:LOCALAPPDATA "Programs\Dolphin"
$script:createDesktopShortcut = $false
$script:openDolphin = $false

function Set-Progress
{
  param([string]$Message, [int]$Percent = -1)

  $statusLabel.Text = $Message
  if ($Percent -lt 0)
  {
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
  }
  else
  {
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $progressBar.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
  }
  [System.Windows.Forms.Application]::DoEvents()
}

function Get-LocalBuild
{
  if (-not [Environment]::Is64BitOperatingSystem)
  {
    throw "Dolphin requires 64-bit Windows."
  }

  $architecture = $env:PROCESSOR_ARCHITEW6432
  if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
  if ($architecture -eq "ARM64")
  {
    $artifactSuffix = "arm64"
  }
  else
  {
    $artifactSuffix = "x64"
  }

  Set-Progress "Checking the bundled $artifactSuffix build..."
  $archives = @(Get-ChildItem -LiteralPath $PSScriptRoot `
      -Filter "dolphin-*-$artifactSuffix.7z" -File -ErrorAction Stop)
  if ($archives.Count -ne 1)
  {
    throw "This installer bundle must contain exactly one $artifactSuffix Dolphin build archive."
  }

  return $archives[0]
}

function Get-7ZipExtractor
{
  Set-Progress "Preparing the bundled archive extractor..."
  $extractorPath = Join-Path $PSScriptRoot "7zr.exe"
  if (-not (Test-Path -LiteralPath $extractorPath -PathType Leaf))
  {
    throw "The installer bundle is missing 7zr.exe."
  }
  return $extractorPath
}

function Expand-BuildArchive
{
  param([string]$Extractor, [string]$Archive, [string]$Destination)

  Set-Progress "Checking the build archive..."
  $listing = @(& $Extractor l -slt $Archive 2>&1)
  if ($LASTEXITCODE -ne 0)
  {
    throw "The bundled build archive could not be read."
  }

  $archiveFullPath = [IO.Path]::GetFullPath($Archive)
  foreach ($line in $listing)
  {
    if ($line -match "^Path = (.+)$")
    {
      $member = $Matches[1]
      if ($member -eq $archiveFullPath) { continue }
      if ([IO.Path]::IsPathRooted($member) -or
          $member -match '(^|[\\/])\.\.([\\/]|$)' -or
          $member -match '^[A-Za-z]:')
      {
        throw "The build archive contains an unsafe file path."
      }
    }
  }

  Set-Progress "Extracting Dolphin..."
  $arguments = "x -y -o`"$Destination`" `"$Archive`""
  $process = Start-Process -FilePath $Extractor -ArgumentList $arguments `
    -WindowStyle Hidden -PassThru
  while (-not $process.HasExited)
  {
    if ($script:cancelRequested)
    {
      $process.Kill()
      throw "Installation was canceled."
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
    $process.Refresh()
  }
  if ($process.ExitCode -ne 0)
  {
    throw "The bundled build archive could not be extracted."
  }
}

function Add-InstallWarning
{
  param([string]$Message)

  if ($script:cleanupWarning) { $script:cleanupWarning += "`r`n" }
  $script:cleanupWarning += $Message
}

function Install-BundledBuild
{
  $script:cleanupWarning = ""
  $script:workDirectory = Join-Path $env:TEMP ("DolphinInstall-" + [guid]::NewGuid().ToString("N"))
  $parentDirectory = Split-Path -Parent $script:installPath
  $stagingDirectory = Join-Path $parentDirectory (".Dolphin-install-" + [guid]::NewGuid().ToString("N"))
  $backupDirectory = Join-Path $parentDirectory (".Dolphin-backup-" + [guid]::NewGuid().ToString("N"))

  try
  {
    New-Item -ItemType Directory -Path $script:workDirectory -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $parentDirectory -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $stagingDirectory -ErrorAction Stop | Out-Null

    $archive = Get-LocalBuild
    $archivePath = $archive.FullName

    $extractor = Get-7ZipExtractor
    $extractDirectory = Join-Path $script:workDirectory "extracted"
    New-Item -ItemType Directory -Path $extractDirectory -ErrorAction Stop | Out-Null
    Expand-BuildArchive $extractor $archivePath $extractDirectory

    $executables = @(Get-ChildItem -Path $extractDirectory -Filter "Dolphin.exe" -File -Recurse)
    if ($executables.Count -ne 1)
    {
      throw "The build archive did not contain exactly one Dolphin.exe."
    }

    $buildDirectory = $executables[0].Directory.FullName
    Get-ChildItem -LiteralPath $buildDirectory -Force |
      Copy-Item -Destination $stagingDirectory -Recurse -Force -ErrorAction Stop
    if ($script:cancelRequested)
    {
      throw "Installation was canceled."
    }

    Set-Progress "Installing Dolphin..."
    if (Test-Path -LiteralPath $script:installPath)
    {
      if (-not (Test-Path -LiteralPath $script:installPath -PathType Container))
      {
        throw "The chosen install path exists and is not a folder."
      }
      if (-not (Test-Path -LiteralPath (Join-Path $script:installPath "Dolphin.exe")) -and
          @(Get-ChildItem -LiteralPath $script:installPath -Force -ErrorAction Stop).Count -gt 0)
      {
        throw "The chosen folder is not empty and is not a Dolphin installation."
      }
      Move-Item -LiteralPath $script:installPath -Destination $backupDirectory -ErrorAction Stop
    }

    try
    {
      Move-Item -LiteralPath $stagingDirectory -Destination $script:installPath -ErrorAction Stop
    }
    catch
    {
      if (Test-Path -LiteralPath $backupDirectory)
      {
        Move-Item -LiteralPath $backupDirectory -Destination $script:installPath -ErrorAction Stop
      }
      throw
    }

    if (Test-Path -LiteralPath $backupDirectory)
    {
      try
      {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction Stop
      }
      catch
      {
        Add-InstallWarning "The previous version could not be removed from $backupDirectory"
      }
    }

    try
    {
      $shell = New-Object -ComObject WScript.Shell
      $startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
      New-Item -ItemType Directory -Path $startMenu -Force -ErrorAction Stop | Out-Null
      $shortcut = $shell.CreateShortcut((Join-Path $startMenu "Dolphin Emulator.lnk"))
      $shortcut.TargetPath = Join-Path $script:installPath "Dolphin.exe"
      $shortcut.WorkingDirectory = $script:installPath
      $shortcut.Save()

      if ($script:createDesktopShortcut)
      {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shortcut = $shell.CreateShortcut((Join-Path $desktop "Dolphin Emulator.lnk"))
        $shortcut.TargetPath = Join-Path $script:installPath "Dolphin.exe"
        $shortcut.WorkingDirectory = $script:installPath
        $shortcut.Save()
      }
    }
    catch
    {
      Add-InstallWarning "Dolphin was installed, but a shortcut could not be created: $($_.Exception.Message)"
    }
  }
  finally
  {
    if (Test-Path -LiteralPath $stagingDirectory)
    {
      try
      {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
      }
      catch
      {
        Add-InstallWarning "Temporary installation files could not be removed from $stagingDirectory"
      }
    }
    if (Test-Path -LiteralPath $script:workDirectory)
    {
      try
      {
        Remove-Item -LiteralPath $script:workDirectory -Recurse -Force -ErrorAction Stop
      }
      catch
      {
        Add-InstallWarning "Temporary installer files could not be removed from $script:workDirectory"
      }
    }
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Dolphin Setup"
$form.ClientSize = New-Object System.Drawing.Size(600, 370)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Dolphin Emulator Setup"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(24, 20)
$title.Size = New-Object System.Drawing.Size(540, 36)
$form.Controls.Add($title)

$separator = New-Object System.Windows.Forms.Panel
$separator.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$separator.Location = New-Object System.Drawing.Point(24, 65)
$separator.Size = New-Object System.Drawing.Size(552, 1)
$form.Controls.Add($separator)

$pages = @{}
foreach ($pageName in @("welcome", "location", "confirm", "progress", "complete"))
{
  $page = New-Object System.Windows.Forms.Panel
  $page.Location = New-Object System.Drawing.Point(24, 82)
  $page.Size = New-Object System.Drawing.Size(552, 220)
  $page.Visible = $false
  $form.Controls.Add($page)
  $pages[$pageName] = $page
}

$welcomeText = New-Object System.Windows.Forms.Label
$welcomeText.Text = "This wizard installs the Windows development build included with this installer bundle.`r`n`r`nAll installation files are local; no network access is needed. Dolphin will be installed for your Windows account only, with no administrator permission."
$welcomeText.Location = New-Object System.Drawing.Point(4, 8)
$welcomeText.Size = New-Object System.Drawing.Size(530, 130)
$pages.welcome.Controls.Add($welcomeText)

$locationLabel = New-Object System.Windows.Forms.Label
$locationLabel.Text = "Install Dolphin in this folder:"
$locationLabel.Location = New-Object System.Drawing.Point(4, 12)
$locationLabel.Size = New-Object System.Drawing.Size(520, 24)
$pages.location.Controls.Add($locationLabel)

$pathTextBox = New-Object System.Windows.Forms.TextBox
$pathTextBox.Text = $script:installPath
$pathTextBox.Location = New-Object System.Drawing.Point(4, 43)
$pathTextBox.Size = New-Object System.Drawing.Size(425, 26)
$pages.location.Controls.Add($pathTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse..."
$browseButton.Location = New-Object System.Drawing.Point(440, 41)
$browseButton.Size = New-Object System.Drawing.Size(95, 28)
$pages.location.Controls.Add($browseButton)
$browseButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = "Choose a folder inside your Windows user profile."
  $dialog.SelectedPath = $pathTextBox.Text
  if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK)
  {
    $pathTextBox.Text = $dialog.SelectedPath
  }
})

$desktopCheckBox = New-Object System.Windows.Forms.CheckBox
$desktopCheckBox.Text = "Create a desktop shortcut"
$desktopCheckBox.Location = New-Object System.Drawing.Point(4, 84)
$desktopCheckBox.Size = New-Object System.Drawing.Size(300, 24)
$pages.location.Controls.Add($desktopCheckBox)

$locationHint = New-Object System.Windows.Forms.Label
$locationHint.Text = "The default location is in LocalAppData. Choose a folder inside your Windows user profile."
$locationHint.Location = New-Object System.Drawing.Point(4, 122)
$locationHint.Size = New-Object System.Drawing.Size(530, 44)
$pages.location.Controls.Add($locationHint)

$confirmText = New-Object System.Windows.Forms.Label
$confirmText.Location = New-Object System.Drawing.Point(4, 8)
$confirmText.Size = New-Object System.Drawing.Size(530, 100)
$pages.confirm.Controls.Add($confirmText)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready."
$statusLabel.Location = New-Object System.Drawing.Point(4, 28)
$statusLabel.Size = New-Object System.Drawing.Size(530, 32)
$pages.progress.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(4, 76)
$progressBar.Size = New-Object System.Drawing.Size(530, 22)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$pages.progress.Controls.Add($progressBar)

$completeText = New-Object System.Windows.Forms.Label
$completeText.Text = "Dolphin has been installed for your Windows account."
$completeText.Location = New-Object System.Drawing.Point(4, 12)
$completeText.Size = New-Object System.Drawing.Size(530, 78)
$pages.complete.Controls.Add($completeText)

$openCheckBox = New-Object System.Windows.Forms.CheckBox
$openCheckBox.Text = "Launch Dolphin when I close this wizard"
$openCheckBox.Checked = $true
$openCheckBox.Location = New-Object System.Drawing.Point(4, 102)
$openCheckBox.Size = New-Object System.Drawing.Size(350, 24)
$pages.complete.Controls.Add($openCheckBox)

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Location = New-Object System.Drawing.Point(24, 320)
$buttonPanel.Size = New-Object System.Drawing.Size(552, 35)
$form.Controls.Add($buttonPanel)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = "< Back"
$backButton.Location = New-Object System.Drawing.Point(310, 2)
$backButton.Size = New-Object System.Drawing.Size(78, 28)
$buttonPanel.Controls.Add($backButton)

$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = "Next >"
$nextButton.Location = New-Object System.Drawing.Point(394, 2)
$nextButton.Size = New-Object System.Drawing.Size(78, 28)
$buttonPanel.Controls.Add($nextButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object System.Drawing.Point(478, 2)
$cancelButton.Size = New-Object System.Drawing.Size(74, 28)
$buttonPanel.Controls.Add($cancelButton)

function Show-Page
{
  param([string]$Name)

  foreach ($pageName in $pages.Keys) { $pages[$pageName].Visible = $pageName -eq $Name }
  $script:currentPage = $Name
  $backButton.Visible = $Name -in @("location", "confirm")
  $nextButton.Visible = $Name -ne "progress"
  $cancelButton.Visible = $Name -notin @("complete")
  $backButton.Enabled = $Name -ne "progress"
  $nextButton.Enabled = $Name -ne "progress"
  $cancelButton.Enabled = $true
  switch ($Name)
  {
    "welcome" { $nextButton.Text = "Next >" }
    "location" { $nextButton.Text = "Next >" }
    "confirm" { $nextButton.Text = "Install" }
    "complete" { $nextButton.Text = "Finish" }
  }
}

$backButton.Add_Click({
  if ($script:currentPage -eq "location") { Show-Page "welcome" }
  elseif ($script:currentPage -eq "confirm") { Show-Page "location" }
})

$nextButton.Add_Click({
  if ($script:currentPage -eq "welcome")
  {
    Show-Page "location"
    return
  }

  if ($script:currentPage -eq "location")
  {
    try
    {
      $candidate = [IO.Path]::GetFullPath($pathTextBox.Text.Trim())
      $userRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') + "\"
      if (-not $candidate.StartsWith($userRoot, [StringComparison]::OrdinalIgnoreCase))
      {
        throw "Choose a folder inside your Windows user profile so the installation does not require administrator permission."
      }
      $script:installPath = $candidate.TrimEnd('\')
      if ((Test-Path -LiteralPath $script:installPath) -and
          -not (Test-Path -LiteralPath $script:installPath -PathType Container))
      {
        throw "The chosen install path exists and is not a folder."
      }
      if ((Test-Path -LiteralPath $script:installPath) -and
          -not (Test-Path -LiteralPath (Join-Path $script:installPath "Dolphin.exe")) -and
          @(Get-ChildItem -LiteralPath $script:installPath -Force -ErrorAction Stop).Count -gt 0)
      {
        throw "Choose an empty folder or an existing Dolphin installation."
      }
      $script:createDesktopShortcut = $desktopCheckBox.Checked
      $confirmText.Text = "The bundled development build will be installed to:`r`n$script:installPath`r`n`r`nAn existing Dolphin installation in this folder will be replaced. Dolphin's user data is kept separately."
      Show-Page "confirm"
    }
    catch
    {
      [System.Windows.Forms.MessageBox]::Show(
        $form, $_.Exception.Message, "Invalid install folder",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    return
  }

  if ($script:currentPage -eq "confirm")
  {
    if (Get-Process -Name Dolphin -ErrorAction SilentlyContinue)
    {
      [System.Windows.Forms.MessageBox]::Show(
        $form, "Close Dolphin before installing the update, then try again.",
        "Dolphin is running", [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
      return
    }

    Show-Page "progress"
    $script:cancelRequested = $false
    $cancelButton.Text = "Cancel"
    $nextButton.Enabled = $false
    $backButton.Enabled = $false
    try
    {
      Install-BundledBuild
      if ($script:cleanupWarning)
      {
        $completeText.Text = "Dolphin was installed with the following notice:`r`n$script:cleanupWarning"
      }
      $openCheckBox.Checked = $true
      Show-Page "complete"
    }
    catch
    {
      $errorMessage = $_.Exception.Message
      $nextButton.Enabled = $true
      $backButton.Enabled = $true
      $cancelButton.Text = "Cancel"
      $cancelButton.Enabled = $true
      Show-Page "confirm"
      if ($script:cleanupWarning) { $errorMessage += "`r`n`r`n" + $script:cleanupWarning }
      [System.Windows.Forms.MessageBox]::Show(
        $form, $errorMessage, "Installation failed",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    return
  }

  if ($script:currentPage -eq "complete")
  {
    $script:openDolphin = $openCheckBox.Checked
    $form.Close()
  }
})

$cancelButton.Add_Click({
  if ($script:currentPage -eq "progress")
  {
    $script:cancelRequested = $true
    $cancelButton.Enabled = $false
    $statusLabel.Text = "Canceling..."
  }
  else
  {
    $form.Close()
  }
})

$form.Add_FormClosing({
  if ($script:currentPage -eq "progress")
  {
    $_.Cancel = $true
    $script:cancelRequested = $true
  }
})

Show-Page "welcome"
[void]$form.ShowDialog()

if ($script:openDolphin -and (Test-Path -LiteralPath (Join-Path $script:installPath "Dolphin.exe")))
{
  Start-Process -FilePath (Join-Path $script:installPath "Dolphin.exe") `
    -WorkingDirectory $script:installPath
}
