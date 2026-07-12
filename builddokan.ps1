# Script that builds dokan
#
# Version: 20260709

Param (
	[string]$Configuration = ${Env:Configuration},
	[string]$Platform = ${Env:Platform},
	[switch]$UseLegacyVersion = $false,
	[string]$MSBuildPath = "",
	[string]$WindowsSdkVersion = "",
	[string]$PlatformToolset = ""
)

$ExitSuccess = 0
$ExitFailure = 1

If (-not ${Configuration})
{
	$Configuration = "Release"
}
If (-not ${Platform})
{
	$Platform = "Win32"
}

If (${MSBuildPath})
{
	$MSBuild = ${MSBuildPath}
}
ElseIf (${Env:AppVeyor} -eq "True")
{
	$MSBuild = "MSBuild.exe"
}
ElseIf (${Env:VisualStudioVersion} -eq "15.0")
{
	$MSBuild = "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\amd64\MSBuild.exe"
}
ElseIf (${Env:VisualStudioVersion} -eq "9.0")
{
	$MSBuild = "C:\\Windows\Microsoft.NET\Framework\v3.5\MSBuild.exe"
}
Else
{
	$MSBuild = "C:\\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
}
$MSBuildOptions = "/verbosity:quiet /target:Build /property:Configuration=${Configuration},Platform=${Platform}"

If (-Not ${UseLegacyVersion})
{
	# dokany's dokan.vcxproj pins WindowsTargetPlatformVersion to a specific
	# SDK release that may not be the one installed on this machine; override
	# it with whatever SDK is actually present instead of patching the
	# (externally synced) project file.
	If (-Not ${WindowsSdkVersion})
	{
		$Results = Get-ChildItem -Path "C:\Program Files (x86)\Windows Kits\10\Include\10.*" -Directory -ErrorAction SilentlyContinue |
			Sort-Object -Property Name -Descending

		If (${Results}.Count -gt 0)
		{
			$WindowsSdkVersion = ${Results}[0].Name
		}
	}
	If (${WindowsSdkVersion})
	{
		$MSBuildOptions = "${MSBuildOptions} /property:WindowsTargetPlatformVersion=${WindowsSdkVersion}"
	}
	# dokan.vcxproj also pins PlatformToolset (eg. v141 for VS2017), which may
	# not be installed alongside a newer Visual Studio; let the caller override
	# it with whatever toolset it already resolved for the main build.
	If (${PlatformToolset})
	{
		$MSBuildOptions = "${MSBuildOptions} /property:PlatformToolset=${PlatformToolset}"
	}
}
If ($UseLegacyVersion)
{
	$DokanPath = "../dokan"
	$ProjectFile = "msvscpp\dokan.sln"
}
Else
{
	$DokanPath = "../dokany"
	$ProjectFile = "dokan\dokan.vcxproj"
}

Push-Location ${DokanPath}

Try
{
	Write-Host "${MSBuild} ${MSBuildOptions} ${ProjectFile}"

	# PowerShell will raise NativeCommandError if MSBuild writes to stdout or stderr
	# therefore 2>&1 is added and the output is stored in a variable.
	$Output = Invoke-Expression -Command "& '${MSBuild}' ${MSBuildOptions} ${ProjectFile} 2>&1" | %{ "$_" }
}
Finally
{
	Pop-Location
}
If (${LastExitCode} -ne 0)
{
	Write-Host ${Output}

	Exit ${ExitFailure}
}
Exit ${ExitSuccess}

