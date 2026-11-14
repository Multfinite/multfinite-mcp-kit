# Shared Windows PowerShell helpers. The caller must check the platform first.
# Keep scripts ASCII-compatible with Windows PowerShell 5.1, which may decode
# UTF-8 files without a BOM using the system ANSI code page.
function Write-KitHeader([string]$Message) {
    $bar = ([string][char]0x2550) * 3
    Write-Host "`n$bar $Message $bar" -ForegroundColor Cyan
}
function Write-KitLine([string]$Label, [ConsoleColor]$Color, [string]$Message) {
    Write-Host "[$Label]" -ForegroundColor $Color -NoNewline
    Write-Host " $Message"
}
function Write-KitInfo([string]$Message) { Write-KitLine 'INFO' Blue $Message }
function Write-KitOk([string]$Message) { Write-KitLine 'OK' Green $Message }
function Write-KitWarn([string]$Message) { Write-KitLine 'WARN' Yellow $Message }
function Write-KitError([string]$Message) { Write-KitLine 'ERROR' Red $Message }

function Protect-PrivateDirectory([string]$Directory) {
    # NTFS does not honour Unix mode 0600. Use SIDs so this also works on
    # non-English Windows. Do not alter the legacy .env or user data.
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if ([IO.Path]::DirectorySeparatorChar -ne '\') { return } # protocol tests on PowerShell Core
    $acl = Get-Acl -LiteralPath $Directory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleAll($rule) }
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagate = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $sids = @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in $sids) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $propagate, $allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
