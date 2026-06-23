<#
.SYNOPSIS
  Neutralise NTFS junctions / symlinks inside a worktree BEFORE git removes it (#19).

.DESCRIPTION
  `git worktree remove --force` follows reparse points and deletes the REAL target
  data (e.g. a junction to a multi-GB trained_models/ dir in the main checkout). This
  script enumerates reparse points under -WorktreePath WITHOUT descending into them
  and unlinks each one (cmd `rmdir` for directories, Remove-Item for file links) — the
  link is removed, the target's data is preserved. It does NOT call git; the caller
  runs `git worktree remove` afterwards.

  NOTE: never use `Remove-Item -Recurse` or `Get-ChildItem -Recurse` on a junction —
  both follow it and would delete the target. This walk skips into reparse points by
  design and only ever uses `cmd /c rmdir`, which unlinks without following.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorktreePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $WorktreePath)) { exit 0 }

# Iterative walk that collects reparse points but never descends into them.
$reparse = [System.Collections.Generic.List[object]]::new()
$stack = [System.Collections.Stack]::new()
$stack.Push((Get-Item -LiteralPath $WorktreePath -Force).FullName)

while ($stack.Count -gt 0) {
  $dir = $stack.Pop()
  foreach ($child in Get-ChildItem -LiteralPath $dir -Force) {
    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $reparse.Add($child)            # a link — record it, do NOT descend
    }
    elseif ($child.PSIsContainer) {
      $stack.Push($child.FullName)    # a real directory — keep walking
    }
  }
}

foreach ($link in $reparse) {
  if ($link.PSIsContainer) {
    # Directory junction/symlink: rmdir removes the reparse point, not the target.
    & cmd.exe /c rmdir "$($link.FullName)"
  }
  else {
    # File symlink: removing the link does not touch its target.
    Remove-Item -LiteralPath $link.FullName -Force
  }
}
