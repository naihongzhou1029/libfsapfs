# Script that drives day-to-day Windows development operations
#
# Commands:
#   env     - pre-flight check/install of toolchains and build dependencies
#   build   - build final products into build\
#   clean   - remove artifacts under build\ (keeps build\vstools)
#   rebuild - clean then build
#   probe   - list disks/partitions and detect APFS container candidates
#   mount   - mount an APFS container via fsapfsmount.exe (Dokan); shows an
#             interactive selection menu when options are omitted
#   unmount - unmount a previously mounted APFS container via dokanctl.exe;
#             shows an interactive selection menu when -MountPoint is omitted
#   gui     - open a small window to mount/unmount APFS containers by
#             picking from a list, instead of using the CLI menus/options
#
# Version: 20260720

Param (
	[Parameter(Position = 0)]
	[ValidateSet("build", "clean", "env", "gui", "help", "mount", "probe", "rebuild", "umount", "unmount")]
	[string]$Command = "help",

	[string]$Configuration = "Release",
	[string]$Platform = "x64",
	[string]$PlatformToolset = "",
	[string]$PythonPath = $(
		If (Test-Path "C:\Python314\python.exe")
		{
			"C:\Python314"
		}
		ElseIf (Get-Command python -ErrorAction SilentlyContinue)
		{
			Split-Path -Parent (Get-Command python).Source
		}
		Else
		{
			"C:\Python314"
		}
	),
	[string]$VisualStudioVersion = "",
	[string]$VSToolsOptions = "--extend-with-x64",
	[string]$BuildDir = "build",
	[switch]$InstallVisualStudio = $false,
	[switch]$InstallDokan = $false,
	[switch]$Hidden = $false,
	[string]$PhysicalDrive = "",
	[string]$Source = "",
	[string]$Offset = "",
	[string]$MountPoint = "",
	[string]$FileSystemIndex = "",
	[string]$Password = "",
	[string]$RecoveryPassword = ""
)

$ExitSuccess = 0
$ExitFailure = 1

$RepositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildPath = "${RepositoryRoot}\${BuildDir}"

Function Get-PackageName
{
	$PackageName = Get-Content -Path "${RepositoryRoot}\configure.ac" |
		select -skip 3 -first 1 |
		% { $_ -Replace "  \[","" } |
		% { $_ -Replace "\],","" }

	Return ${PackageName}
}

Function Invoke-Step
{
	Param (
		[string]$Description,
		[string]$ScriptPath,
		[hashtable]$ScriptArguments = @{}
	)

	If (-Not (Test-Path -Path ${ScriptPath}))
	{
		Write-Warning "Skipping ${Description}: missing ${ScriptPath}"

		Return $TRUE
	}
	Write-Host ""
	Write-Host "== ${Description} ==" -ForegroundColor Cyan

	$global:LASTEXITCODE = 0

	# Splatting a hashtable (not an array of "-Name","value" strings) is
	# required for PowerShell to bind these as named parameters.
	# Output is forced through the host directly so it is never swallowed by
	# a caller that captures Invoke-Step's own return value (eg. via -Not (...)).
	& ${ScriptPath} @ScriptArguments | Out-Host

	If (${LastExitCode} -eq 1)
	{
		Write-Error "${Description} failed with exit code ${LastExitCode}"

		Return $FALSE
	}
	Return $TRUE
}

Function Test-WingetAvailable
{
	Return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

Function Install-WithWinget
{
	Param (
		[string]$PackageId,
		[string]$DisplayName,
		[string]$ExtraArguments = ""
	)

	If (-Not (Test-WingetAvailable))
	{
		Write-Warning "winget is not available, install ${DisplayName} manually"

		Return $FALSE
	}
	Write-Host "Installing ${DisplayName} via winget (${PackageId}) ..."

	$Command = "winget install --id ${PackageId} -e --silent --accept-package-agreements --accept-source-agreements"

	If (${ExtraArguments})
	{
		$Command = "${Command} ${ExtraArguments}"
	}
	$Output = Invoke-Expression -Command "${Command} 2>&1" | %{ "$_" }
	Write-Host ${Output}

	Return $TRUE
}

Function Get-DefaultPlatformToolset
{
	Param (
		[string]$VisualStudioVersion
	)

	# Mirrors build.ps1's own Visual Studio version -> PlatformToolset mapping
	# so dokan is built with a toolset that is actually installed alongside it.
	Switch (${VisualStudioVersion})
	{
		"2017" { Return "v141" }
		"2019" { Return "v142" }
		"2022" { Return "v143" }
		"2026" { Return "v145" }
		Default { Return "v143" }
	}
}

Function Test-DokanDriverInstalled
{
	If (Get-Service -Name "dokan1" -ErrorAction SilentlyContinue)
	{
		Return $TRUE
	}
	If (Test-Path -Path "C:\Windows\System32\drivers\dokan1.sys")
	{
		Return $TRUE
	}
	Return $FALSE
}

Function Test-CppWorkload
{
	Param (
		[string]$MSBuildPath
	)

	# MSBuild.exe alone does not imply the C++ workload is installed; the
	# VC targets (VCTargetsPath) only exist when "Desktop development with
	# C++" was selected in the Visual Studio installer.
	$VSInstallDir = ${MSBuildPath} -Replace "\\MSBuild\\Current\\Bin\\MSBuild\.exe$", ""

	If (${VSInstallDir} -eq ${MSBuildPath})
	{
		Return $FALSE
	}
	$Results = Get-ChildItem -Path "${VSInstallDir}\MSBuild\Microsoft\VC\*\Microsoft.Cpp.Default.props" -ErrorAction SilentlyContinue

	Return [bool](${Results}.Count -gt 0)
}

Function Find-MSBuild
{
	$Candidates = @()

	$MSBuildCommand = Get-Command "MSBuild.exe" -ErrorAction SilentlyContinue

	If (${MSBuildCommand})
	{
		$Candidates += ${MSBuildCommand}.Source
	}
	ForEach (${VSYear} in @("2022", "2019"))
	{
		ForEach (${ProgramFiles} in @("C:\Program Files", "C:\Program Files (x86)"))
		{
			$Results = Get-ChildItem -Path "${ProgramFiles}\Microsoft Visual Studio\${VSYear}\*\MSBuild\Current\Bin\MSBuild.exe" -ErrorAction SilentlyContinue -Force

			ForEach (${Result} in ${Results})
			{
				$Candidates += ${Result}.FullName
			}
		}
	}
	# Prefer a candidate that actually has the C++ workload installed;
	# otherwise fall back to the first MSBuild.exe found so the caller can
	# still report its path (with a clear warning that the workload is
	# missing) rather than nothing at all.
	ForEach (${Candidate} in ${Candidates})
	{
		If (Test-CppWorkload -MSBuildPath ${Candidate})
		{
			Return @{ Path = ${Candidate}; HasCppWorkload = $TRUE }
		}
	}
	If (${Candidates}.Count -gt 0)
	{
		Return @{ Path = ${Candidates}[0]; HasCppWorkload = $FALSE }
	}
	Return @{ Path = ""; HasCppWorkload = $FALSE }
}

Function Invoke-Env
{
	Write-Host ""
	Write-Host "== Toolchain ==" -ForegroundColor Cyan

	$Result = $TRUE

	$Git = Get-Command git -ErrorAction SilentlyContinue

	If (-Not ${Git})
	{
		Write-Warning "git not found"

		If (Install-WithWinget -PackageId "Git.Git" -DisplayName "Git")
		{
			$Git = Get-Command git -ErrorAction SilentlyContinue
		}
	}
	If (${Git})
	{
		Write-Host "git: $(${Git}.Source)" -ForegroundColor Green
	}
	Else
	{
		Write-Error "git is required and could not be installed automatically"

		$Result = $FALSE
	}
	If (Test-Path "${PythonPath}\python.exe")
	{
		Write-Host "python: ${PythonPath}\python.exe" -ForegroundColor Green
	}
	Else
	{
		Write-Warning "python not found at ${PythonPath}"

		If (Install-WithWinget -PackageId "Python.Python.3.13" -DisplayName "Python")
		{
			$PythonCommand = Get-Command python -ErrorAction SilentlyContinue

			If (${PythonCommand})
			{
				Write-Host "python: $(${PythonCommand}.Source)" -ForegroundColor Green
			}
			Else
			{
				Write-Error "python is required and could not be located after installation, set -PythonPath"

				$Result = $FALSE
			}
		}
		Else
		{
			Write-Error "python is required, install it and/or set -PythonPath"

			$Result = $FALSE
		}
	}
	$MSBuild = Find-MSBuild

	If (${MSBuild}.Path -and ${MSBuild}.HasCppWorkload)
	{
		Write-Host "MSBuild: $(${MSBuild}.Path) (C++ workload present)" -ForegroundColor Green
	}
	Else
	{
		If (${MSBuild}.Path)
		{
			Write-Warning "MSBuild found ($(${MSBuild}.Path)) but the 'Desktop development with C++' workload is missing"
		}
		Else
		{
			Write-Warning "MSBuild / Visual Studio not found"
		}
		If (${InstallVisualStudio})
		{
			$VSInstallerPath = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe"
			If (${MSBuild}.Path -and (Test-Path -Path $VSInstallerPath))
			{
				$VSInstallDir = ${MSBuild}.Path -Replace "\\MSBuild\\Current\\Bin\\MSBuild\.exe$", ""
				Write-Host "Visual Studio Installer found. Modifying existing MSBuild installation to add C++ workload, compiler tools, and Windows 10 SDK..." -ForegroundColor Cyan
				Start-Process -FilePath $VSInstallerPath -ArgumentList 'modify', '--installPath', "`"${VSInstallDir}`"", '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '--add', 'Microsoft.VisualStudio.Component.Windows10SDK.19041', '--passive', '--norestart' -Verb RunAs -Wait
			}
			Else
			{
				Write-Host "Installing Visual Studio 2022 Build Tools with C++ workload, compiler tools, and Windows 10 SDK..." -ForegroundColor Cyan
				Install-WithWinget -PackageId "Microsoft.VisualStudio.2022.BuildTools" -DisplayName "Visual Studio 2022 Build Tools" -ExtraArguments '--override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.19041"' | Out-Null
			}

			Write-Warning "Installer completed; re-run '.\devops.ps1 env' to verify"
		}
		Else
		{
			Write-Warning "Run '.\devops.ps1 env -InstallVisualStudio' to attempt an unattended install via winget, or install the 'Desktop development with C++' workload manually"
		}
		$Result = $FALSE
	}
	Write-Host ""
	Write-Host "== Build dependencies ==" -ForegroundColor Cyan
	Write-Host "Note: zlib and the local library dependencies (libbfio, libcerror, ...) are"
	Write-Host "kept at their existing locations (..\zlib and the repository root) because"
	Write-Host "the checked-in msvscpp\*.vcproj files reference them via hardcoded relative"
	Write-Host "paths. Only vstools (a build-time tool, not a compiled dependency) lives"
	Write-Host "under ${BuildDir}\vstools."

	If (-Not (Invoke-Step -Description "Synchronizing local library dependencies" -ScriptPath "${RepositoryRoot}\synclibs.ps1")) { $Result = $FALSE }
	If (-Not (Invoke-Step -Description "Synchronizing zlib" -ScriptPath "${RepositoryRoot}\synczlib.ps1")) { $Result = $FALSE }

	Write-Host ""
	Write-Host "== Dokan (fsapfsmount) ==" -ForegroundColor Cyan
	Write-Host "Using dokany (the actively maintained fork, supports x64/ARM64) at ..\dokany,"
	Write-Host "not the legacy 0.6.0 fork the checked-in msvscpp\fsapfsmount.vcproj defaults"
	Write-Host "to; 'build' passes --with-dokany so the generated solution points at it."

	$DokanInstalled = Test-DokanDriverInstalled
	If (-Not $DokanInstalled)
	{
		Write-Warning "Dokan kernel driver (dokan1.sys) is not installed."
		If (${InstallDokan})
		{
			Write-Host "Installing Dokan Library v1.5.1.1000 via winget..." -ForegroundColor Cyan
			Install-WithWinget -PackageId "dokan-dev.Dokany" -DisplayName "Dokan Library v1.5.1.1000" -ExtraArguments "-v 1.5.1.1000" | Out-Null
			Write-Warning "Dokan installer launched; please verify the installation (requires reboot or service restart)"
		}
		Else
		{
			Write-Warning "Run '.\devops.ps1 env -InstallDokan' to attempt an unattended install of Dokan Library v1.5.1.1000 via winget"
		}
	}
	Else
	{
		Write-Host "Dokan kernel driver detected (dokan1 service or driver file present)." -ForegroundColor Green
	}

	If (-Not (Invoke-Step -Description "Synchronizing dokan" -ScriptPath "${RepositoryRoot}\syncdokan.ps1")) { $Result = $FALSE }

	$DokanPlatformToolset = If (${PlatformToolset}) { ${PlatformToolset} } Else { Get-DefaultPlatformToolset -VisualStudioVersion ${VisualStudioVersion} }

	$BuildDokanArguments = @{
		Configuration   = ${Configuration}
		Platform        = ${Platform}
		PlatformToolset = ${DokanPlatformToolset}
	}
	If (${MSBuild}.Path) { $BuildDokanArguments.MSBuildPath = ${MSBuild}.Path }

	If (-Not (Invoke-Step -Description "Building dokan" -ScriptPath "${RepositoryRoot}\builddokan.ps1" -ScriptArguments ${BuildDokanArguments})) { $Result = $FALSE }

	Return ${Result}
}

Function Invoke-Build
{
	If (-Not (Test-Path -Path ${BuildPath}))
	{
		New-Item -ItemType Directory -Path ${BuildPath} -Force | Out-Null
	}
	$OutputPath = "${BuildPath}\${Configuration}\${Platform}\"

	$EffectiveVSToolsOptions = ${VSToolsOptions}

	If (${EffectiveVSToolsOptions} -NotMatch "--with[-_]dokany")
	{
		$EffectiveVSToolsOptions = "${EffectiveVSToolsOptions} --with-dokany"
	}
	$BuildArguments = @{
		Configuration  = ${Configuration}
		Platform       = ${Platform}
		PythonPath     = ${PythonPath}
		VSToolsOptions = ${EffectiveVSToolsOptions}
		VSToolsPath    = "${BuildPath}\vstools"
		OutDir         = ${OutputPath}
	}
	If (${PlatformToolset}) { $BuildArguments.PlatformToolset = ${PlatformToolset} }
	If (${VisualStudioVersion}) { $BuildArguments.VisualStudioVersion = ${VisualStudioVersion} }

	# A machine can have multiple Visual Studio installs; only some may have
	# the C++ workload. Reuse the same workload-aware search as 'env' instead
	# of letting build.ps1 fall back to whichever MSBuild.exe is first on PATH.
	$MSBuild = Find-MSBuild

	If (${MSBuild}.Path) { $BuildArguments.MSBuildPath = ${MSBuild}.Path }

	If (${MSBuild}.Path -and -not ${MSBuild}.HasCppWorkload)
	{
		Write-Warning "MSBuild found ($(${MSBuild}.Path)) but the 'Desktop development with C++' workload appears to be missing; run '.\devops.ps1 env' for details"
	}
	$Result = Invoke-Step -Description "Building $(Get-PackageName)" -ScriptPath "${RepositoryRoot}\build.ps1" -ScriptArguments ${BuildArguments}

	If (${Result})
	{
		# fsapfsmount.exe dynamically links dokan1.dll; without it alongside
		# the exe it cannot even start, let alone mount anything.
		$DokanDll = "${RepositoryRoot}\..\dokany\dokan\${Platform}\${Configuration}\dokan1.dll"

		If ((Test-Path -Path "${OutputPath}\fsapfsmount.exe") -and (Test-Path -Path ${DokanDll}))
		{
			Copy-Item -Path ${DokanDll} -Destination ${OutputPath} -Force
		}
		Write-Host ""
		Write-Host "Final products: ${OutputPath}" -ForegroundColor Green
	}
	Return ${Result}
}

Function Invoke-Clean
{
	If (-Not (Test-Path -Path ${BuildPath}))
	{
		Write-Host "Nothing to clean: ${BuildPath} does not exist"

		Return $TRUE
	}
	Get-ChildItem -Path ${BuildPath} -Force |
		Where-Object { $_.Name -ne "vstools" } |
		ForEach-Object {
			Write-Host "Removing: $($_.FullName)"

			Remove-Item -Path $_.FullName -Force -Recurse
		}
	Return $TRUE
}

Function Invoke-Rebuild
{
	If (-Not (Invoke-Clean)) { Return $FALSE }

	Return (Invoke-Build)
}

Function Test-IsElevated
{
	$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal(${CurrentIdentity})

	Return ${CurrentPrincipal}.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

Function Hide-ConsoleWindow
{
	# Hiding via Start-Process's own -WindowStyle Hidden is not used for the
	# 'gui' command because combining it with -Verb RunAs (see mount-gui.bat)
	# creates the WinForms window itself already hidden (Visible=$FALSE), not
	# just the console; hiding this process's own console after the fact,
	# from inside the process, sidesteps that entirely regardless of how the
	# process was launched (elevated or not).
	Add-Type -Name Win32ConsoleWindow -Namespace DevopsGui -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue

	$ConsoleHandle = [DevopsGui.Win32ConsoleWindow]::GetConsoleWindow()

	If (${ConsoleHandle} -ne [IntPtr]::Zero)
	{
		[DevopsGui.Win32ConsoleWindow]::ShowWindow(${ConsoleHandle}, 0) | Out-Null # SW_HIDE
	}
}

Function Find-DokanCtl
{
	ForEach (${ProgramFiles} in @("C:\Program Files", "C:\Program Files (x86)"))
	{
		# The version directory (eg. "DokanLibrary-1.5.1") makes this a fixed
		# depth glob, so it does not also match the x86\dokanctl.exe alongside
		# the native one.
		$Results = Get-ChildItem -Path "${ProgramFiles}\Dokan\*\dokanctl.exe" -ErrorAction SilentlyContinue -Force

		If (${Results})
		{
			Return ${Results}[0].FullName
		}
	}
	Return ""
}

Function Get-ApfsPartitionCandidates
{
	# GPT partition type GUID Apple assigns to APFS containers.
	$ApfsGptType = "{7c3457ef-0000-11aa-aa11-00306543ecac}"

	Return Get-Partition -ErrorAction SilentlyContinue |
		Where-Object { $_.GptType -and ($_.GptType -eq ${ApfsGptType}) }
}

Function Read-MenuChoice
{
	Param (
		[string]$Title,
		[string[]]$Options,
		[string]$Prompt = "Select an option"
	)

	Write-Host ""
	Write-Host "${Title}" -ForegroundColor Cyan

	For ($Index = 0; ${Index} -lt ${Options}.Count; $Index++)
	{
		Write-Host ("  [{0}] {1}" -f (${Index} + 1), ${Options}[${Index}])
	}
	Write-Host "  [q] Cancel"

	While ($TRUE)
	{
		Try
		{
			$Answer = Read-Host -Prompt "${Prompt} (1-$(${Options}.Count) or q)"
		}
		Catch
		{
			# Read-Host is unavailable in a non-interactive host; treat as cancel
			# so callers fall back to their normal missing-option error path.
			Return -1
		}
		If ((-Not ${Answer}) -or (${Answer} -Match "^[Qq]$"))
		{
			Return -1
		}
		$Number = 0

		If ([int]::TryParse(${Answer}, [ref]${Number}) -and (${Number} -ge 1) -and (${Number} -le ${Options}.Count))
		{
			Return ${Number} - 1
		}
		Write-Warning "Invalid selection: ${Answer}"
	}
}

Function Get-FreeDriveLetters
{
	Param (
		[int]$MaximumCount = 10
	)

	$UsedLetters = @()

	ForEach (${Drive} in [System.IO.DriveInfo]::GetDrives())
	{
		$UsedLetters += ${Drive}.Name.Substring(0, 1).ToUpper()
	}
	$FreeLetters = @()

	# Walk from Z: downwards; low letters (A:-C:) are more likely to collide
	# with floppy/system conventions, and D:+ often belongs to real volumes.
	ForEach (${LetterCode} in (90..68))
	{
		$Letter = [string][char]${LetterCode}

		If (${UsedLetters} -NotContains ${Letter})
		{
			$FreeLetters += "${Letter}:"
		}
		If (${FreeLetters}.Count -ge ${MaximumCount})
		{
			Break
		}
	}
	# No leading comma: callers wrap the call in @(...), which would count a
	# comma-wrapped empty array as one element instead of zero.
	Return ${FreeLetters}
}

Function Get-FsApfsMountInstances
{
	# fsapfsmount.exe blocks for the lifetime of the mount, so each running
	# instance corresponds to one active mount; its mount point is the last
	# command line argument (see Invoke-Mount).
	$Processes = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'fsapfsmount.exe'" -ErrorAction SilentlyContinue

	$Instances = @()

	ForEach (${Process} in ${Processes})
	{
		If (-Not ${Process}.CommandLine)
		{
			Continue
		}
		$Tokens = @([regex]::Matches(${Process}.CommandLine, '("[^"]*"|\S+)') | ForEach-Object { $_.Value.Trim('"') })

		If (${Tokens}.Count -lt 3)
		{
			Continue
		}
		# Recovers the -o offset (see Invoke-Mount) so a running instance can
		# be matched back to its source Get-Partition candidate by
		# (Source, Offset) rather than by Source alone, since one physical
		# drive can host more than one APFS container at different offsets.
		$OffsetIndex = [array]::IndexOf(${Tokens}, "-o")
		$InstanceOffset = If ((${OffsetIndex} -ge 0) -and ((${OffsetIndex} + 1) -lt ${Tokens}.Count)) { ${Tokens}[${OffsetIndex} + 1] } Else { "" }

		$Instances += [PSCustomObject]@{
			ProcessId  = ${Process}.ProcessId
			Source     = ${Tokens}[-2]
			MountPoint = ${Tokens}[-1]
			Offset     = ${InstanceOffset}
		}
	}
	# No leading comma: callers wrap the call in @(...), which would count a
	# comma-wrapped empty array as one element instead of zero.
	Return ${Instances}
}

Function Invoke-Probe
{
	Write-Host ""
	Write-Host "== Disks ==" -ForegroundColor Cyan

	$Disks = Get-Disk -ErrorAction SilentlyContinue

	If (-Not ${Disks})
	{
		Write-Warning "No disks found (Get-Disk returned nothing)"

		Return $FALSE
	}
	$Disks |
		Select-Object Number, FriendlyName, BusType, PartitionStyle, @{ Name = "SizeGB"; Expression = { [Math]::Round($_.Size / 1GB, 1) } }, IsBoot, IsSystem |
		Format-Table -AutoSize |
		Out-Host

	Write-Host "== APFS container candidates ==" -ForegroundColor Cyan
	Write-Host "Detected via GPT partition type 7c3457ef-0000-11aa-aa11-00306543ecac (Apple APFS)."

	$Candidates = Get-ApfsPartitionCandidates

	If (-Not ${Candidates})
	{
		Write-Warning "No GPT partitions with the APFS type GUID were found."
		Write-Warning "If the disk uses MBR, or the container lives at a raw offset the type GUID does not cover, inspect 'Get-Partition' output above and pass -PhysicalDrive/-Offset to 'mount' manually."

		Return $TRUE
	}
	$FsApfsInfoPath = "${BuildPath}\${Configuration}\${Platform}\fsapfsinfo.exe"
	$HaveFsApfsInfo = Test-Path -Path ${FsApfsInfoPath}
	$IsElevated = Test-IsElevated

	ForEach (${Candidate} in ${Candidates})
	{
		$DiskNumber = ${Candidate}.DiskNumber
		$PartitionNumber = ${Candidate}.PartitionNumber
		$CandidateOffset = ${Candidate}.Offset
		$PhysicalDrivePath = "\\.\PhysicalDrive${DiskNumber}"
		$SizeGB = [Math]::Round(${Candidate}.Size / 1GB, 1)

		Write-Host ""
		Write-Host "Disk ${DiskNumber} Partition ${PartitionNumber}:" -ForegroundColor Green
		Write-Host "  Source : ${PhysicalDrivePath}"
		Write-Host "  Offset : ${CandidateOffset}"
		Write-Host "  Size   : ${SizeGB} GB"
		Write-Host "  Mount  : .\devops.ps1 mount -PhysicalDrive ${DiskNumber} -Offset ${CandidateOffset} -MountPoint X:"

		If (${HaveFsApfsInfo} -and ${IsElevated})
		{
			Try
			{
				$Info = & ${FsApfsInfoPath} -o "${CandidateOffset}" ${PhysicalDrivePath} 2>&1

				Write-Host (${Info} -join "`n")
			}
			Catch
			{
				Write-Warning "fsapfsinfo failed against ${PhysicalDrivePath}: $($_.Exception.Message)"
			}
		}
		ElseIf (-Not ${IsElevated})
		{
			Write-Host "  (Run as Administrator to also probe container/volume details via fsapfsinfo.exe)" -ForegroundColor DarkGray
		}
		ElseIf (-Not ${HaveFsApfsInfo})
		{
			Write-Host "  (Build fsapfsinfo.exe via '.\devops.ps1 build' to also probe container/volume details)" -ForegroundColor DarkGray
		}
	}
	Return $TRUE
}

Function Invoke-Mount
{
	# Parameters default to the like-named script-level bound values so CLI
	# dispatch (Invoke-Mount with no args) is unaffected; Invoke-Gui calls
	# this with explicit values instead, which also skips the interactive
	# menus below since ${ResolvedSource}/${ResolvedMountPoint} come pre-filled.
	Param (
		[string]$Source = ${Source},
		[string]$PhysicalDrive = ${PhysicalDrive},
		[string]$Offset = ${Offset},
		[string]$MountPoint = ${MountPoint},
		[string]$FileSystemIndex = ${FileSystemIndex},
		[string]$Password = ${Password},
		[string]$RecoveryPassword = ${RecoveryPassword}
	)

	# Elevation is checked first so the user is not walked through the
	# interactive menus below only to fail at the actual mount step.
	If (-Not (Test-IsElevated))
	{
		Write-Error "Mounting requires an elevated (Administrator) PowerShell session"

		Return $FALSE
	}
	$ResolvedSource = ${Source}
	$ResolvedOffset = ${Offset}
	$ResolvedMountPoint = ${MountPoint}

	If ((-Not ${ResolvedSource}) -and ${PhysicalDrive})
	{
		$ResolvedSource = "\\.\PhysicalDrive${PhysicalDrive}"
	}
	If (-Not ${ResolvedSource})
	{
		# No -PhysicalDrive/-Source given: fall back to an interactive menu of
		# detected APFS containers so the user does not have to run 'probe'
		# and copy the options over by hand.
		$Candidates = @(Get-ApfsPartitionCandidates)

		If (${Candidates}.Count -eq 0)
		{
			Write-Error "Missing source and no APFS container candidates were detected: pass -PhysicalDrive <number> (see '.\devops.ps1 probe') or -Source <path>"

			Return $FALSE
		}
		$MenuOptions = @()

		ForEach (${Candidate} in ${Candidates})
		{
			$SizeGB = [Math]::Round(${Candidate}.Size / 1GB, 1)

			$MenuOptions += "\\.\PhysicalDrive$(${Candidate}.DiskNumber) partition $(${Candidate}.PartitionNumber), offset $(${Candidate}.Offset), ${SizeGB} GB"
		}
		$Choice = Read-MenuChoice -Title "Select the APFS container to mount" -Options ${MenuOptions}

		If (${Choice} -lt 0)
		{
			Write-Warning "Mount cancelled: pass -PhysicalDrive <number> (see '.\devops.ps1 probe') or -Source <path>"

			Return $FALSE
		}
		$ResolvedSource = "\\.\PhysicalDrive$(${Candidates}[${Choice}].DiskNumber)"

		If (-Not ${ResolvedOffset})
		{
			$ResolvedOffset = "$(${Candidates}[${Choice}].Offset)"
		}
	}
	If (-Not ${ResolvedMountPoint})
	{
		# No -MountPoint given: offer the free drive letters as a menu.
		$FreeDriveLetters = @(Get-FreeDriveLetters)

		If (${FreeDriveLetters}.Count -eq 0)
		{
			Write-Error "Missing -MountPoint and no free drive letters were found: pass -MountPoint <empty directory>"

			Return $FALSE
		}
		$Choice = Read-MenuChoice -Title "Select a drive letter to mount at" -Options ${FreeDriveLetters}

		If (${Choice} -lt 0)
		{
			Write-Warning "Mount cancelled: pass -MountPoint <drive letter (eg. X:) or empty directory>"

			Return $FALSE
		}
		$ResolvedMountPoint = ${FreeDriveLetters}[${Choice}]
	}
	$FsApfsMountPath = "${BuildPath}\${Configuration}\${Platform}\fsapfsmount.exe"

	If (-Not (Test-Path -Path ${FsApfsMountPath}))
	{
		Write-Error "fsapfsmount.exe not found at ${FsApfsMountPath}; run '.\devops.ps1 build' first"

		Return $FALSE
	}
	If (-Not (Test-Path -Path "${BuildPath}\${Configuration}\${Platform}\dokan1.dll"))
	{
		Write-Warning "dokan1.dll not found alongside fsapfsmount.exe; it will fail to start"
	}
	If (-Not (Test-DokanDriverInstalled))
	{
		Write-Warning "Dokan kernel driver does not appear to be installed; run '.\devops.ps1 env -InstallDokan'"
	}
	$Arguments = @()

	If (${ResolvedOffset}) { $Arguments += @("-o", ${ResolvedOffset}) }
	If (${FileSystemIndex}) { $Arguments += @("-f", ${FileSystemIndex}) }
	If (${Password}) { $Arguments += @("-p", ${Password}) }
	If (${RecoveryPassword}) { $Arguments += @("-r", ${RecoveryPassword}) }
	$Arguments += @(${ResolvedSource}, ${ResolvedMountPoint})

	$LogDir = "${BuildPath}\mount-logs"

	If (-Not (Test-Path -Path ${LogDir}))
	{
		New-Item -ItemType Directory -Path ${LogDir} -Force | Out-Null
	}
	$LogName = (${ResolvedMountPoint} -Replace "[:\\/]", "_")
	$StdOutLog = "${LogDir}\${LogName}.out.log"
	$StdErrLog = "${LogDir}\${LogName}.err.log"

	Write-Host ""
	Write-Host "== Mounting ${ResolvedSource} at ${ResolvedMountPoint} ==" -ForegroundColor Cyan

	# fsapfsmount.exe blocks in DokanMain() for the lifetime of the mount (it
	# never daemonizes on Windows), so it is launched detached here; otherwise
	# this command would never return control to the caller.
	$Process = Start-Process -FilePath ${FsApfsMountPath} -ArgumentList ${Arguments} -WindowStyle Hidden -RedirectStandardOutput ${StdOutLog} -RedirectStandardError ${StdErrLog} -PassThru

	Start-Sleep -Milliseconds 1500

	If (${Process}.HasExited)
	{
		Write-Error "fsapfsmount.exe exited immediately (exit code $(${Process}.ExitCode)); see ${StdErrLog}"

		Get-Content -Path ${StdErrLog} -ErrorAction SilentlyContinue | Out-Host

		Return $FALSE
	}
	Write-Host "Mounted. PID $(${Process}.Id); logs: ${StdOutLog} / ${StdErrLog}" -ForegroundColor Green
	Write-Host "Unmount with: .\devops.ps1 unmount -MountPoint ${ResolvedMountPoint}"

	Return $TRUE
}

Function Invoke-Unmount
{
	# Defaults to the script-level bound -MountPoint so CLI dispatch is
	# unaffected; Invoke-Gui calls this with an explicit value instead,
	# which also skips the interactive menu below.
	Param (
		[string]$MountPoint = ${MountPoint}
	)

	# Elevation is checked first so the user is not walked through the
	# interactive menu below only to fail at the actual unmount step.
	If (-Not (Test-IsElevated))
	{
		Write-Error "Unmounting requires an elevated (Administrator) PowerShell session"

		Return $FALSE
	}
	$ResolvedMountPoint = ${MountPoint}

	If (-Not ${ResolvedMountPoint})
	{
		# No -MountPoint given: fall back to an interactive menu of running
		# fsapfsmount.exe instances so the user can pick the mount to release.
		$Instances = @(Get-FsApfsMountInstances)

		If (${Instances}.Count -eq 0)
		{
			Write-Error "Missing -MountPoint <drive letter (eg. X: or X) or mount path> and no running fsapfsmount.exe instances were found"

			Return $FALSE
		}
		$MenuOptions = @()

		ForEach (${Instance} in ${Instances})
		{
			$MenuOptions += "$(${Instance}.MountPoint) (source $(${Instance}.Source), PID $(${Instance}.ProcessId))"
		}
		$Choice = Read-MenuChoice -Title "Select the mount to unmount" -Options ${MenuOptions}

		If (${Choice} -lt 0)
		{
			Write-Warning "Unmount cancelled: pass -MountPoint <drive letter (eg. X: or X) or mount path>"

			Return $FALSE
		}
		$ResolvedMountPoint = ${Instances}[${Choice}].MountPoint
	}
	$DokanCtlPath = Find-DokanCtl

	If (-Not ${DokanCtlPath})
	{
		Write-Error "dokanctl.exe not found under Program Files\Dokan; is Dokan Library installed?"

		Return $FALSE
	}
	# dokanctl expects a bare drive letter (eg. "X") for drive-letter mount
	# points, not "X:" or "X:\"; folder mount points are passed through as-is.
	$DokanMountPoint = ${ResolvedMountPoint}

	If (${DokanMountPoint} -Match "^[A-Za-z]:\\?$")
	{
		$DokanMountPoint = ${DokanMountPoint}.Substring(0, 1)
	}
	Write-Host ""
	Write-Host "== Unmounting ${ResolvedMountPoint} ==" -ForegroundColor Cyan

	# Captured (rather than piped straight to Out-Host) so Invoke-Gui can
	# surface it in a MessageBox too; its own console is normally hidden
	# (see mount-gui.bat), so Out-Host alone would leave failures silent.
	$DokanCtlOutput = (& ${DokanCtlPath} /u ${DokanMountPoint} 2>&1 | ForEach-Object { "$_" }) -join "`n"
	$Script:LastDokanCtlOutput = ${DokanCtlOutput}

	Write-Host ${DokanCtlOutput}

	If (${LastExitCode} -ne 0)
	{
		Write-Error "dokanctl /u ${DokanMountPoint} failed with exit code ${LastExitCode}"

		Return $FALSE
	}
	Return $TRUE
}

Function Get-MountableApfsDisks
{
	# A candidate is mountable if no currently running fsapfsmount.exe
	# instance already has it as its source; matched by (Source, Offset)
	# rather than Source alone, since one physical drive can host more than
	# one APFS container at different offsets.
	$Candidates = @(Get-ApfsPartitionCandidates)
	$Instances = @(Get-FsApfsMountInstances)

	$MountedKeys = @{}

	ForEach (${Instance} in ${Instances})
	{
		$MountedKeys["$(${Instance}.Source)|$(${Instance}.Offset)"] = $TRUE
	}
	Return @(${Candidates} | Where-Object {
		$Key = "\\.\PhysicalDrive$($_.DiskNumber)|$($_.Offset)"

		-Not ${MountedKeys}.ContainsKey(${Key})
	})
}

Function Invoke-Gui
{
	# Checked up front (rather than only disabling the buttons) so the user
	# is not shown a window whose only two actions would silently fail.
	If (-Not (Test-IsElevated))
	{
		Write-Error "The GUI's mount/unmount actions require an elevated (Administrator) PowerShell session"

		Return $FALSE
	}
	If (${Hidden})
	{
		Hide-ConsoleWindow
	}
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing

	[System.Windows.Forms.Application]::EnableVisualStyles()

	$Form = New-Object System.Windows.Forms.Form
	$Form.Text = "libfsapfs - APFS Mount Manager"
	$Form.ClientSize = New-Object System.Drawing.Size(360, 390)
	$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
	$Form.MaximizeBox = $FALSE
	$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

	$MountLabel = New-Object System.Windows.Forms.Label
	$MountLabel.Text = "Mountable Disks:"
	$MountLabel.Location = New-Object System.Drawing.Point(15, 15)
	$MountLabel.AutoSize = $TRUE

	$MountListBox = New-Object System.Windows.Forms.ListBox
	$MountListBox.Location = New-Object System.Drawing.Point(15, 38)
	$MountListBox.Size = New-Object System.Drawing.Size(330, 110)

	$MountButton = New-Object System.Windows.Forms.Button
	$MountButton.Text = "Mount"
	$MountButton.Location = New-Object System.Drawing.Point(15, 156)
	$MountButton.Size = New-Object System.Drawing.Size(100, 30)

	$UnmountLabel = New-Object System.Windows.Forms.Label
	$UnmountLabel.Text = "Unmountable Disks:"
	$UnmountLabel.Location = New-Object System.Drawing.Point(15, 200)
	$UnmountLabel.AutoSize = $TRUE

	$UnmountListBox = New-Object System.Windows.Forms.ListBox
	$UnmountListBox.Location = New-Object System.Drawing.Point(15, 223)
	$UnmountListBox.Size = New-Object System.Drawing.Size(330, 110)

	$UnmountButton = New-Object System.Windows.Forms.Button
	$UnmountButton.Text = "UnMount"
	$UnmountButton.Location = New-Object System.Drawing.Point(15, 341)
	$UnmountButton.Size = New-Object System.Drawing.Size(100, 30)

	$Form.Controls.AddRange(@(${MountLabel}, ${MountListBox}, ${MountButton}, ${UnmountLabel}, ${UnmountListBox}, ${UnmountButton}))

	# A Hashtable (a reference type) so the click handlers below - each
	# invoked in their own child scope by the WinForms event dispatcher -
	# can mutate the selection-to-object mapping in place; a plain array
	# variable reassigned inside a handler would only shadow it locally and
	# never actually update it for the *next* click.
	$State = @{
		MountableCandidates  = @()
		UnmountableInstances = @()
	}

	$RefreshLists = {
		$Mountable = @(Get-MountableApfsDisks)
		$Instances = @(Get-FsApfsMountInstances)

		$State.MountableCandidates = ${Mountable}
		$State.UnmountableInstances = ${Instances}

		$MountListBox.Items.Clear()

		ForEach (${Candidate} in ${Mountable})
		{
			$SizeGB = [Math]::Round(${Candidate}.Size / 1GB, 1)

			$MountListBox.Items.Add("PhysicalDrive$(${Candidate}.DiskNumber) Partition$(${Candidate}.PartitionNumber) (offset $(${Candidate}.Offset), ${SizeGB} GB)") | Out-Null
		}
		$HasMountable = ${Mountable}.Count -gt 0
		$MountListBox.Enabled = ${HasMountable}
		$MountButton.Enabled = ${HasMountable}

		$UnmountListBox.Items.Clear()

		ForEach (${Instance} in ${Instances})
		{
			$UnmountListBox.Items.Add("$(${Instance}.MountPoint)  <-  $(${Instance}.Source)  (PID $(${Instance}.ProcessId))") | Out-Null
		}
		$HasUnmountable = ${Instances}.Count -gt 0
		$UnmountListBox.Enabled = ${HasUnmountable}
		$UnmountButton.Enabled = ${HasUnmountable}
	}

	$MountButton.Add_Click({
		If (${MountListBox}.SelectedIndex -lt 0)
		{
			[System.Windows.Forms.MessageBox]::Show("Select a disk to mount first.", "Mount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null

			Return
		}
		$Candidate = ${State}.MountableCandidates[${MountListBox}.SelectedIndex]
		$FreeDriveLetters = @(Get-FreeDriveLetters -MaximumCount 1)

		If (${FreeDriveLetters}.Count -eq 0)
		{
			[System.Windows.Forms.MessageBox]::Show("No free drive letters are available.", "Mount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null

			Return
		}
		$TargetMountPoint = ${FreeDriveLetters}[0]

		If (Invoke-Mount -PhysicalDrive "$(${Candidate}.DiskNumber)" -Offset "$(${Candidate}.Offset)" -MountPoint ${TargetMountPoint})
		{
			[System.Windows.Forms.MessageBox]::Show("Mounted at ${TargetMountPoint}.", "Mount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
		}
		Else
		{
			[System.Windows.Forms.MessageBox]::Show("Mount failed; see the logs under ${BuildPath}\mount-logs\ for details.", "Mount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
		}
		& ${RefreshLists}
	})

	$UnmountButton.Add_Click({
		If (${UnmountListBox}.SelectedIndex -lt 0)
		{
			[System.Windows.Forms.MessageBox]::Show("Select a disk to unmount first.", "Unmount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null

			Return
		}
		$Instance = ${State}.UnmountableInstances[${UnmountListBox}.SelectedIndex]

		If (Invoke-Unmount -MountPoint ${Instance}.MountPoint)
		{
			[System.Windows.Forms.MessageBox]::Show("Unmounted $(${Instance}.MountPoint).", "Unmount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
		}
		Else
		{
			$Detail = If (${Script:LastDokanCtlOutput}) { "`n`n${Script:LastDokanCtlOutput}" } Else { "" }

			[System.Windows.Forms.MessageBox]::Show("Unmount failed.${Detail}", "Unmount", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
		}
		& ${RefreshLists}
	})

	& ${RefreshLists}

	$Form.ShowDialog() | Out-Null
	$Form.Dispose()

	Return $TRUE
}

Function Show-Help
{
	Write-Host @"
devops.ps1 - major development operations for libfsapfs on Windows

Usage: .\devops.ps1 <command> [options]

Commands:
  env       Pre-flight check of toolchains (git, python, MSBuild/VS C++ build
            tools) and build dependencies (local libs, zlib, dokan for
            fsapfsmount), installing what is missing where possible
  build     Build final products into ${BuildDir}\<Configuration>\<Platform>\
  clean     Remove artifacts under ${BuildDir}\ (keeps ${BuildDir}\vstools)
  rebuild   clean, then build
  probe     List disks/partitions and detect APFS container candidates
            (GPT partition type 7c3457ef-0000-11aa-aa11-00306543ecac)
  mount     Mount an APFS container via fsapfsmount.exe (Dokan). Requires an
            elevated (Administrator) session and the Dokan kernel driver.
            Without -PhysicalDrive/-Source and/or -MountPoint an interactive
            menu of detected APFS containers / free drive letters is shown
  unmount   Unmount a container previously mounted via dokanctl.exe. Requires
            an elevated (Administrator) session. Without -MountPoint an
            interactive menu of running fsapfsmount.exe mounts is shown.
            'umount' is accepted as an alias
  gui       Open a small fixed-size window listing mountable/unmountable APFS
            disks with Mount/UnMount buttons, in place of the CLI options
            above. Requires an elevated (Administrator) session
  help      Show this help (default)

Options:
  -Configuration <Release|Debug>       Default: Release
  -Platform <x64|Win32|ARM64>          Default: x64
  -VisualStudioVersion <2019|2022>     Default: auto-detected by build.ps1
  -PythonPath <path>                   Default: auto-detected
  -BuildDir <path>                     Default: build
  -InstallVisualStudio                 Let 'env' attempt an unattended
                                        install of VS Build Tools via winget
  -InstallDokan                        Let 'env' attempt an unattended
                                        install of Dokan Library v1.5.1.1000 via winget
  -Hidden                              'gui' only: hide this process's own
                                        console window once elevation is
                                        confirmed (used by mount-gui.bat)

Mount/unmount options:
  -PhysicalDrive <number>               Disk number (from 'probe'), resolved
                                         to \\.\PhysicalDrive<number>
  -Source <path>                        Explicit source instead of
                                         -PhysicalDrive (eg. a container image)
  -Offset <bytes>                       Container offset in bytes (from 'probe')
  -MountPoint <drive|path>               eg. X: or C:\mount\apfs
  -FileSystemIndex <index|all>          Default: all
  -Password <password>                  Container password (or passphrase)
  -RecoveryPassword <password>          Container recovery password/passphrase

Examples:
  .\devops.ps1 env
  .\devops.ps1 build
  .\devops.ps1 rebuild -Configuration Debug -Platform x64
  .\devops.ps1 probe
  .\devops.ps1 mount -PhysicalDrive 1 -Offset 135266304 -MountPoint X:
  .\devops.ps1 mount                  (interactive menu)
  .\devops.ps1 unmount -MountPoint X:
  .\devops.ps1 unmount                (interactive menu)
  .\devops.ps1 gui                    (mount/unmount from a window)
"@
	Return $TRUE
}

$Result = $TRUE

Switch (${Command})
{
	"env" { $Result = Invoke-Env }
	"build" { $Result = Invoke-Build }
	"clean" { $Result = Invoke-Clean }
	"rebuild" { $Result = Invoke-Rebuild }
	"probe" { $Result = Invoke-Probe }
	"mount" { $Result = Invoke-Mount }
	# "umount" is accepted as an alias for habit's sake (Unix spelling).
	"umount" { $Result = Invoke-Unmount }
	"unmount" { $Result = Invoke-Unmount }
	"gui" { $Result = Invoke-Gui }
	Default { $Result = Show-Help }
}

If (${Result})
{
	Exit ${ExitSuccess}
}
Exit ${ExitFailure}


