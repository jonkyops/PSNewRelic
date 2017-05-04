# PSake makes variables declared here available in other scriptblocks
# Init some things
Properties {
    # Find the build folder based on build system
    $ProjectRoot = $ENV:BHProjectPath
    $ModuleName = $ENV:BHProjectName
    $BuildTags = $ENV:BuildTags

    if (-not $ProjectRoot) {
        $ProjectRoot = Resolve-Path "$PSScriptRoot\.."
    }

    $ENV:BHModulePath

    $Timestamp = Get-Date -UFormat "%Y%m%d-%H%M%S"
    $PSVersion = $PSVersionTable.PSVersion.Major
    $TestFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
    $lines = '----------------------------------------------------------------------'

    $Verbose = @{}
    if ($ENV:BHCommitMessage -match "!verbose") {
        $Verbose = @{Verbose = $True}
    }
}

Task Default -Depends Test

Task Init {
    $Lines
    Set-Location $ProjectRoot
    "Build System Details:"
    Get-Item ENV:BH*
    "`n"
}

Task Analyze -Depends Init {
    $Lines
    $SaResults = @()
    $Public = @(Get-ChildItem -Path $PSScriptRoot\$ModuleName\Public\*.ps1 -ErrorAction SilentlyContinue)
    $Private = @(Get-ChildItem -Path $PSScriptRoot\$ModuleName\Private\*.ps1 -ErrorAction SilentlyContinue)

    'Running script analyzer to check code quality `r`n'

    foreach($Script in @($Public + $Private)) {
        "Checking $($Script.Name)..."
        $SaResults += Invoke-ScriptAnalyzer -Path $Script.FullName -Severity @('Error','Warning') -Recurse -Verbose:$false
    }

    if ($SaResults) {
        $SaResults | Format-Table
        Write-Error -Message 'One or more Script Analyzer errors/warnings where found. Build cannot continue!'
    }
    else {
        "Code looks clean, good job! `r`n"
    }
}

Task Test -Depends Analyze {
    $lines
    "`n`tSTATUS: Testing with PowerShell $PSVersion"

    # Gather test results. Store them in a variable and file
    $TestResults = Invoke-Pester -Path $ProjectRoot\Tests -PassThru -OutputFormat NUnitXml -OutputFile "$ProjectRoot\$TestFile"

    # In Appveyor?  Upload our tests! #Abstract this into a function?
    if ($ENV:BHBuildSystem -eq 'AppVeyor') {
        (New-Object 'System.Net.WebClient').UploadFile(
            "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
            "$ProjectRoot\$TestFile" )
    }

    Remove-Item "$ProjectRoot\$TestFile" -Force -ErrorAction SilentlyContinue

    # Failed tests?
    # Need to tell psake or it will proceed to the deployment. Danger!
    if ($TestResults.FailedCount -gt 0) {
        Write-Error "Failed '$($TestResults.FailedCount)' tests, build failed"
    }
    "`n"
}

Task Build -Depends UpdateHelp, Test {
    $lines

    # Load the module, read the exported functions, update the psd1 FunctionsToExport
    Set-ModuleFunctions

    # Bump the module version
    try {
        $Version = Get-NextPSGalleryVersion -Name $env:BHProjectName -ErrorAction Stop
        Update-Metadata -Path $env:BHPSModuleManifest -PropertyName ModuleVersion -Value $Version -ErrorAction stop
    }
    catch {
        "Failed to update version for '$env:BHProjectName': $_.`nContinuing with existing version"
    }
}

task CreateMarkdownHelp -Depends Init {
    $Lines

    Import-Module -Name $env:BHModulePath -Force -Verbose:$false -Global
    New-MarkdownHelp -Module $env:BHProjectName -OutputFolder "$projectRoot\docs\" -WithModulePage -Force
    Remove-Module $env:BHProjectName
} -description 'Create initial markdown help files'

Task Deploy -Depends Build {
    $Lines

    $Params = @{
        Path = "$ProjectRoot\Build"
        Force = $true
        Recurse = $false # We keep psdeploy artifacts, avoid deploying those : )
    }
    Invoke-PSDeploy @Verbose @Params
}