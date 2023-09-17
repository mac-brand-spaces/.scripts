# Set-ExecutionPolicy -Scope Process Unrestricted -Force; C:\Users\Marius\Documents\setup-dev-env.ps1

function Get-CurrentlyAdmin {
  $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Get-CurrentlyAdmin)) {
  throw "Script must be run as Administrator!"
  exit 1
}

# set execution policy to unrestricted
Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force

###### helpers

function reloadPath {
  $newPath = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User") + ";" + $env:Path
  $newPathList = $newPath.Split(";")
  $newPathNoDuplicates = $newPathList | Select-Object -Unique
  $env:Path = [system.String]::Join(";", $newPathNoDuplicates)
}

function Check-Installed ([string] $name) {
  reloadPath
  return (Get-Command $name -ErrorAction SilentlyContinue) -ne $null
}

function Add-WingetApp ([string]$name, [string]$id) {
  if (-not (Check-Installed $name)) {
    winget install -e --id $id
    reloadPath
  }
}

###### Winget

Function Check-Winget-Installed {
  return (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
}

Function Install-MsUiXaml {
  $p = "~"
  Invoke-WebRequest -Uri https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.7.3 -OutFile "$p/microsoft.ui.xaml.2.7.3.zip"
  Expand-Archive "$p/microsoft.ui.xaml.2.7.3.zip" -Force
  try {
    Add-AppxPackage "$p\microsoft.ui.xaml.2.7.3\tools\AppX\x64\Release\Microsoft.UI.Xaml.2.7.appx" -Confirm:$false
  } finally {
    Remove-Item "$p\microsoft.ui.xaml.2.7.3\" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$p\microsoft.ui.xaml.2.7.3.zip" -Force -ErrorAction SilentlyContinue
  }
}
Function Install-Winget-GitHub {
  $p = "~"
  $downloadUrl = ((Invoke-WebRequest -Uri https://api.github.com/repos/microsoft/winget-cli/releases/latest -UseBasicParsing).Content | ConvertFrom-Json).assets.ForEach({ if ($_.name.EndsWith(".msixbundle")) { $_.browser_download_url } })
  if ($downloadUrl.Length -lt 1) {
    throw "could not parse download url"
  }
  Invoke-WebRequest -Uri $downloadUrl[0] -OutFile "$p\winget.msixbundle"
  try {
    Add-AppxPackage "$p\winget.msixbundle" -Confirm:$false
  } catch {
    Remove-Item "$p\winget.msixbundle" -Force
    throw $_
  }
  Remove-Item "$p\winget.msixbundle" -Force -ErrorAction SilentlyContinue
}

Function Install-Winget-PowershellGallery {
  Install-Module -Name Microsoft.WinGet.Client -Confirm
}

if (-not (Check-Winget-Installed)) {
  try {
    Install-MsUiXaml
  } finally {
    try {
      Install-Winget-GitHub
    } catch {
      try {
        Install-Winget-PowershellGallery
      } catch {
        Write-Error "Failed to install Winget"
      }
    }
  }
}

####### install git/gh
Add-WingetApp git Git.Git
Add-WingetApp gpg GnuPG.Gpg4win

### setup gh
$ghRequiredScopes = @("admin:public_key", "delete:packages", "gist", "write:gpg_key", "read:org", "repo", "write:packages")
$ghScopesArgs = $ghRequiredScopes | ForEach-Object {@("-s", $_)}
Add-WingetApp gh GitHub.cli
gh auth status -h github.com -t > Out-Null
if ($LASTEXITCODE -ne 0) {
  # login and create ssh key
  gh auth login -p ssh -h github.com -w $ghScopesArgs
}

## check gh scopes
$ghScopesText = (gh auth status | Select-String -Pattern "Token scopes:").ToString()
$ghScopes = [regex]::match($ghScopesText, '(?<=:\s).*').Value.Replace(" ", "").Split(",")
$ghAllScopesFine = $true

$ghRequiredScopes.ForEach({
  if ($ghScopes -notcontains $_) {
    $ghAllScopesFine = $false
  }
})
if (-not $ghAllScopesFine) {
  gh auth refresh -h github.com $ghScopesArgs
}

# get git data
$me = gh api /user | ConvertFrom-Json
$email = "$($me.login)+$($me.id)@users.noreply.github.com"
$username = $me.login

## setup git
git config --global user.email $email
git config --global user.name $username

## setup gpg sining
function Add-NewGpgKey {
  return (gpg --quick-generate-key "$username () <$email>" rsa4096 cert never).Split("`n")[1].Replace(" ", "")
}

if ((git config --global --get user.signingkey) -eq $null) {
  $newKey = Add-NewGpgKey
  git config --global gpg.program ((Get-Command gpg).Path)
  git config --global commit.gpgsign true
  git config --global --unset gpg.format
  git config --global user.signingkey $newKey
  $gpgKey = (gpg --armor --export $newKey)
  $gpgKey | gh gpg-key add -
  if ($LASTEXITCODE -ne 0) {
    $gpgKey | Set-Clipboard
    Write-Host "`n`n`nNow a broswer will open. Paste the contents in your clipboard in the big text box. then press the green button."
    Write-Host -NoNewLine 'Press any key to continue...';
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
    Start-Process "https://github.com/settings/gpg/new"
  }
}

### install github desktop

# winget install -e --id GitHub.GitHubDesktop
winget list GitHub.GitHubDesktop | Out-Null
if ($LASTEXITCODE -ne 0) {
  winget install -e --id GitHub.GitHubDesktop
}

###### install vscode
reloadPath
if (-not (Check-Installed code)) {
  Install-Script -Name Install-VSCode -Confirm:$false
  Install-VSCode -Confirm:$false -ErrorAction Continue
  Uninstall-Script -Name Install-VSCode
}

###### install aws-cli v2
reloadPath
if (-not (Check-Installed aws)) {
  # https://gist.github.com/dansmith65/1691f9f0145194ce067323a5787b71bd
  # https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  $dlurl = "https://awscli.amazonaws.com/AWSCLIV2.msi"
  $installerPath = Join-Path $env:TEMP (Split-Path $dlurl -Leaf)
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest $dlurl -OutFile $installerPath
  Start-Process -FilePath msiexec -Args "/i $installerPath /passive" -Verb RunAs -Wait
  Remove-Item $installerPath
  $env:Path += ";C:\Program Files\Amazon\AWSCLIV2"
}

reloadPath
if (-not (Check-Installed node)) {
  winget install -e --id OpenJS.NodeJS -v 18.11.0
}
