# Script that drives day-to-day Windows development operations
#
# Commands:
#   env     - pre-flight check/install of toolchains and build dependencies
#   build   - build final products into build\
#   clean   - remove artifacts under build\ (keeps build\vstools)
#   rebuild - clean then build
#
# Version: 20260709

Param (
	[Parameter(Position = 0)]
	[ValidateSet("build", "clean", "env", "help", "rebuild")]
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
	[switch]$InstallDokan = $false
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

Examples:
  .\devops.ps1 env
  .\devops.ps1 build
  .\devops.ps1 rebuild -Configuration Debug -Platform x64
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
	Default { $Result = Show-Help }
}

If (${Result})
{
	Exit ${ExitSuccess}
}
Exit ${ExitFailure}


