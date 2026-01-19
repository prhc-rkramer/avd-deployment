################################################################################
#
# Copyright © 2024 Epic Systems Corporation
#
################################################################################

#Requires -Version 4.0
<#
.Synopsis
   Repairs the Hyperdrive registration for Azure Virtual Desktop machines after running a sysprep.

.DESCRIPTION
   The script checks for key files in %PROGRAMDATA%\Microsoft\Crypto\Keys and copies any that do not match the machine's GUID to a new file with a fixed name.

.EXAMPLE
    .\Repair-HyperdriveRegistration.ps1

    Saves a transcript to the current directory, determines the current machine GUID from the registry,
    checks for any key files that do not match the current machine GUID, and creates copies of those files that match the machine's GUID.

.EXAMPLE
    .\Repair-HyperdriveRegistration.ps1 -LoggingDirectory "C:\temp"

    Saves a transcript to C:\temp, determines the current machine GUID from the registry,
    checks for any key files that do not match the current machine GUID, and creates copies of those files that match the machine's GUID.

.PARAMETER LoggingDirectory
    Optional: Path to an existing directory where the transcript should be saved to.
    If not included, the transcript will be saved to the current directory.
#>

param
(
    [Parameter(Mandatory = $false)]
    $LoggingDirectory
)

<#
.Synopsis
    Tests that the logging directory can be accessed, and starts the transcript.

.Parameter LoggingDirectory
    Path to the directory where the transcript should be saved.
#>
function Test-LoggingDirectory
{
    param
    (
        [Parameter(Mandatory = $true)]
        $LoggingDirectory
    )
    if (-not (Test-Path -Path $LoggingDirectory))
    {
        Write-Error -Message "$LoggingDirectory does not exist."
        return
    }

    # Start transcribing
    $fileName = "$(Get-Date -Format FileDateTime)_RegistrationFixTranscript.txt"
    try
    {
        Stop-Transcript -ErrorAction Stop
    }
    catch
    {
        # Do nothing, this is fine
    }
    
    try
    {
        Start-Transcript -Path (Join-Path -Path $LoggingDirectory -ChildPath $fileName) -ErrorAction Stop
    }
    catch
    {
        Write-Error -Message "Failed to start transcript. Confirm that the user running this script has permission to create allKeyFiles in $LoggingDirectory."
    }
}

<#
.Synopsis
    Obtains the machine's current GUID from the registry.
    If the registry cannot be accessed, the script will throw an error and exit.

.Outputs
    A string of the machine's current GUID from the registry.
#>
function Get-CurrentMachineGuid
{
    Write-Host "Obtaining current machine GUID from registry..."
    try
    {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $cryptoKey = $hklm.OpenSubKey("Software\Microsoft\Cryptography", $false)
        $currentMachineGuid = $cryptoKey.GetValue("MachineGuid")

        Write-Host "Found current machine GUID $currentMachineGuid"
        return $currentMachineGuid
    }
    catch
    {
        Write-Error -Message "Failed to determine current GUID from registry data. Wowrk with your Client Systems - Hyperspace & Desktop TS to troubleshoot further."
        Invoke-ScriptExit
    }    
}

<#
.Synopsis
    Determines which key files need to be renamed to fix Hyperdrive registration`

.Parameter CurrentMachineGuid
    String containing the machine's current GUID

.Outputs
    If there are key files in need of renaming, returns an array of those file objects.
    If there are not any key files in need of renaming, the script will exit gracefully.
    If not able to find any key files at all, the script will throw an error and exit.
#>
function Get-KeyFilesToRename
{
    param
    (
        [Parameter(Mandatory = $true)]
        $CurrentMachineGuid
    )

    Write-Host "Identifying existing key allKeyFiles..."

    $keyDirectory = [System.IO.Path]::Combine("$Env:Programdata", "Microsoft", "Crypto", "Keys")
    if (-not (Test-Path -Path $keyDirectory))
    {
        Write-Error -Message "$keyDirectory does not exist. Make sure that this directory exists."
        Invoke-ScriptExit
    }

    try
    {
        $allKeyFiles = Get-ChildItem $keyDirectory -ErrorAction SilentlyContinue
    }
    catch
    {
        Write-Error -Message "Unable to access $keyDirectory. Make sure that the user running this script has pemissions to view its contents."
        Invoke-ScriptExit
    }

    $filesInNeedOfConversion = @()

    foreach ($file in $allKeyFiles)
    {
        $fileParts = $file.Name.Split("_")

        if ($fileParts.Length -lt 2)
        {
            continue # Invalid file format, don't touch it
        }
    
        # Dissect the file name
        $containerPart = $fileParts[0]
        $machinePart = $fileParts[1]
        if ($fileParts.Length -gt 2) { $sidPart = $fileParts[2] }
        else { $sidPart = "" }

        # Don't touch the file for the current machine GUID
        if ($machinePart.Equals($CurrentMachineGuid, [System.StringComparison]::OrdinalIgnoreCase))
        {
            continue 
        }

        $filesInNeedOfConversion += $file
    }

    $numFilesToConvert = $filesInNeedOfConversion.Length

    if ($numFilesToConvert -eq 0)
    {
        Write-Host "No key files in need of fixing."
        Invoke-ScriptExit
    }

    if ($numFilesToConvert -gt 0)
    {
        Write-Host "Identified $numCount key allKeyFiles in need of fixing."
    }

    return , $filesInNeedOfConversion
}

<#
.Synopsis
    Creates a new key file with a name corresponding to the machine's current GUID.
    If unable to create the new file, the script will throw a warning.

.Parameter File
    File object representing a key file that will be renamed.

.Parameter CurrentMachineGuid
    String with the machine's current GUID
#>
function Copy-FileToNewNamingScheme
{
    param
    (
        [Parameter(Mandatory = $true)]
        $File,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $CurrentMachineGuid
    )

    Write-Host "Processing $($file.FullName) for an updated machine key..."

    # Dissect the file name
    $fileParts = $file.Name.Split("_") 
    $containerPart = $fileParts[0]
    if ($fileParts.Length -gt 2) { $sidPart = $fileParts[2] } else { $sidPart = "" }

    # Create the new file
    $newFileName = "$($containerPart)_$($CurrentMachineGuid)"
    if (-not [System.String]::IsNullOrWhiteSpace($sidPart))
    {
        $newFileName = "$($newFileName)_$($sidPart)"
    }

    $fullNewFileName = [System.IO.Path]::Combine($file.DirectoryName, $newFileName)
    try
    {
        $file.CopyTo($fullNewFileName)
    }
    catch
    {
        Write-Warning -Message "Failed to create file $fullNewFileName"
    }
}

<#
.Synopsis
    Stops the transcript and exits the script
#>
function Invoke-ScriptExit
{
    try
    {
        Stop-Transcript -ErrorAction Stop    
    }
    catch
    {
        # Do nothing
    }

    exit
}

# region main
if ($null -eq $LoggingDirectory) { $LoggingDirectory = $PSScriptRoot} # Has to be bound in the script itself, not in the parameter definition

Test-LoggingDirectory -LoggingDirectory $LoggingDirectory

$currentMachineGuid = Get-CurrentMachineGuid

$keyFilesToRename = Get-KeyFilesToRename -CurrentMachineGuid $currentMachineGuid

foreach ($file in $keyFilesToRename)
{
    Copy-FileToNewNamingScheme -File $file -CurrentMachineGuid $currentMachineGuid
}

Write-Host "Re-registration complete"

# endregion main
# SIG # Begin signature block
# MIIfggYJKoZIhvcNAQcCoIIfczCCH28CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAS+4uA4Ss9AwAH
# Avk3mmIUriEkVjB7GQwBV0MtQ4kOOqCCDaswggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wggbzMIIE26ADAgECAhAO614UTyg+R2Lj4sqgJSYSMA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjIwOTI3MDAwMDAwWhcNMjUwODE1
# MjM1OTU5WjB4MQswCQYDVQQGEwJVUzESMBAGA1UECBMJV2lzY29uc2luMQ8wDQYD
# VQQHEwZWZXJvbmExITAfBgNVBAoTGEVwaWMgU3lzdGVtcyBDb3Jwb3JhdGlvbjEh
# MB8GA1UEAxMYRXBpYyBTeXN0ZW1zIENvcnBvcmF0aW9uMIIBojANBgkqhkiG9w0B
# AQEFAAOCAY8AMIIBigKCAYEA0hCw4wBL/V6kWwOejVoMhssdFsJoHucqDJ2P3d1y
# 1iiwDw8OXO/tkWLKtjKyei4plU1VABVFy+FHDHX8DVzFze/Ph2kpS6bxQaCXVXLh
# s+6V8/y0MaXiOGSbr2wxFOOnDdND10IxPRU+nG+VUfLEsiW4M3UO4Wvqhk/UvHM9
# GzOQ0D+yhntsDTGTdNkxFQZFCDBv75F75sH4SKU9VxgzGJV8VusqphdvTdQflKVY
# uSHFKBChmmUBWQLlR/I9Hpyx07r3A11MNJ+EgRQxA+Whmhad40p+k4tjSgQSbLxf
# 8Zj+p/0M1dCHAHh34vXY/zsbOc6hDhGAlpzMupDMS6kul7x9ZZICPLwvauuTKUe1
# 7M1RRkIzoMz4S9Uprmuq3OgTdWqeNk+GJJFGmyxB/7NxxAJwcbV35DvX+FMStA6k
# p6ZKMiAaOjYFyh6asQhItIlQiLfOSThkuMsA3WaRwd8+PoOMoC3xB7NoWWihkB7/
# 9bwIKoce2WEacPunmLfGhmWZAgMBAAGjggIGMIICAjAfBgNVHSMEGDAWgBRoN+Dr
# tjv4XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQUsqmzA+nzVYvVBUrX7GgVYF5x/1sw
# DgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8Ega0w
# gaowU6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBPhk1o
# dHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2ln
# bmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDA+BgNVHSAENzA1MDMGBmeBDAEE
# ATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwgZQG
# CCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2Vy
# dC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEu
# Y3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAJgoPniffkhEnXEB
# A1HpxTL+My03bRu141KM/N59uAWZgRArcdfaRYaWhtKWnjs2n9dYqVWJ6i7WRaxt
# R9Xu533Djqb8NkSL8rVe82aycvVazXmioInX9KB8hfDHWf0IsWEVM/G4o0SdtT3U
# 05QpWIJwYyidIzi1nqNEVqoy5jYiNUuH+DuLQxenNOtDxH2R8pb+vnJ6D0haEpp0
# IMwduAnZtBVlUuHQGY4NHtCiIfhMuazTTH/7nT51Mw+uVY4/nh9xHnxGBxSwo6yA
# 84G+XexWujtdZB7JtcWZApRavUK9opcaKxEkL4qPmZh+JBw9Nov9Ex+kbaJOggqX
# W5jFsspE/xPsOJpy0E0vktIm1M1ldGYckG3SnFCPFC9uJlpCBXwDYLBq0tiTjrH/
# FlVjBusxiCV+CfscJASeSSYzvfWbOZO5omP6ckQAna+rfMLJUQ9P/hFKIZKyt2LU
# jClSIg7z5yha42aVDkRP7DrSIIHF4/3NLnG1+8Jti7werPSTd2MdsZ8N3FL4C24l
# 5W5VYCYhd0PBnv7X0zSmM+tLHnuUWFFDq71XFTOAqfmuqRL/k8Y0p6ogLzPjBdFW
# Ze569xKHjsyhdBOLcqR/y5nbq3ssFWr6FZmte4HHmFkaeRPltj/yVcQRKog9Ff6d
# AlPqJTGpTLvBuv6Si/J6niyGZyiQMYIRLTCCESkCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhAO
# 614UTyg+R2Lj4sqgJSYSMA0GCWCGSAFlAwQCAQUAoIHCMBkGCSqGSIb3DQEJAzEM
# BgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqG
# SIb3DQEJBDEiBCC2zqnggkBNNbRLJgGS0nURvTP/O6GkjjR+11PpEnC2rjBWBgor
# BgEEAYI3AgEMMUgwRqBEgEIAUgBlAHAAYQBpAHIALQBIAHkAcABlAHIAZAByAGkA
# dgBlAFIAZQBnAGkAcwB0AHIAYQB0AGkAbwBuAC4AcABzADEwDQYJKoZIhvcNAQEB
# BQAEggGAZI2gxOQfuH7LjOZrjBJvpOcBey/czwIM3J501SJXtSygJfLpEHqy/XMx
# RAD4vFP8sWeS1PGonNEs0L3+EW3VyOnFUlnUxnkggE9pHoTKCWAKD498+G5qEZL1
# ghf2WaJ5KlNud+yjJJrsIJE3L3hesc+O5DmYBftTNHC6LaIrr7sLjE8oCrY+GEye
# MfhntKcJ7SfticK9xLCPvu1ANyn9tdTYoFsFc4cn2efyVjdEsL/5RNma9JXbU6so
# 7DB6Ol3tBO59GCGfnIgJ+5VGfThXYeRz7nJukXlh978b2MWra+BpODp0wSqsK3qV
# i64DRWXv/Te0h2HbRhrDW2Al28r++19uXcc4yzF6cnKeFGDQVMwVnsSnxEBMAozp
# YucbPydTjLGz2jw4cI5Cdnw9g4tvpRxZpJJHFUl02v74WMuf/gwUOYbHDzlPiL5R
# KsGiCJE4wldCJuvmCDxjp+dwBEjXERgukEqMoH8y9ofWgUFCDw851RZ3De7wkB9D
# En4YlCzkoYIOPDCCDjgGCisGAQQBgjcDAwExgg4oMIIOJAYJKoZIhvcNAQcCoIIO
# FTCCDhECAQMxDTALBglghkgBZQMEAgEwggEOBgsqhkiG9w0BCRABBKCB/gSB+zCB
# +AIBAQYLYIZIAYb4RQEHFwMwMTANBglghkgBZQMEAgEFAAQge1faSXAutWQJ/dgR
# E9Ce1IqIb1gX9mvSuXgEZvIgVUACFF1kepxvIIX5clNmGaNDEHWl8XatGA8yMDI0
# MDIyNzIyNDYwMlowAwIBHqCBhqSBgzCBgDELMAkGA1UEBhMCVVMxHTAbBgNVBAoT
# FFN5bWFudGVjIENvcnBvcmF0aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBO
# ZXR3b3JrMTEwLwYDVQQDEyhTeW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIFNp
# Z25lciAtIEczoIIKizCCBTgwggQgoAMCAQICEHsFsdRJaFFE98mJ0pwZnRIwDQYJ
# KoZIhvcNAQELBQAwgb0xCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5WZXJpU2lnbiwg
# SW5jLjEfMB0GA1UECxMWVmVyaVNpZ24gVHJ1c3QgTmV0d29yazE6MDgGA1UECxMx
# KGMpIDIwMDggVmVyaVNpZ24sIEluYy4gLSBGb3IgYXV0aG9yaXplZCB1c2Ugb25s
# eTE4MDYGA1UEAxMvVmVyaVNpZ24gVW5pdmVyc2FsIFJvb3QgQ2VydGlmaWNhdGlv
# biBBdXRob3JpdHkwHhcNMTYwMTEyMDAwMDAwWhcNMzEwMTExMjM1OTU5WjB3MQsw
# CQYDVQQGEwJVUzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xHzAdBgNV
# BAsTFlN5bWFudGVjIFRydXN0IE5ldHdvcmsxKDAmBgNVBAMTH1N5bWFudGVjIFNI
# QTI1NiBUaW1lU3RhbXBpbmcgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQC7WZ1ZVU+djHJdGoGi61XzsAGtPHGsMo8Fa4aaJwAyl2pNyWQUSym7wtkp
# uS7sY7Phzz8LVpD4Yht+66YH4t5/Xm1AONSRBudBfHkcy8utG7/YlZHz8O5s+K2W
# OS5/wSe4eDnFhKXt7a+Hjs6Nx23q0pi1Oh8eOZ3D9Jqo9IThxNF8ccYGKbQ/5IMN
# JsN7CD5N+Qq3M0n/yjvU9bKbS+GImRr1wOkzFNbfx4Dbke7+vJJXcnf0zajM/gn1
# kze+lYhqxdz0sUvUzugJkV+1hHk1inisGTKPI8EyQRtZDqk+scz51ivvt9jk1R1t
# ETqS9pPJnONI7rtTDtQ2l4Z4xaE3AgMBAAGjggF3MIIBczAOBgNVHQ8BAf8EBAMC
# AQYwEgYDVR0TAQH/BAgwBgEB/wIBADBmBgNVHSAEXzBdMFsGC2CGSAGG+EUBBxcD
# MEwwIwYIKwYBBQUHAgEWF2h0dHBzOi8vZC5zeW1jYi5jb20vY3BzMCUGCCsGAQUF
# BwICMBkaF2h0dHBzOi8vZC5zeW1jYi5jb20vcnBhMC4GCCsGAQUFBwEBBCIwIDAe
# BggrBgEFBQcwAYYSaHR0cDovL3Muc3ltY2QuY29tMDYGA1UdHwQvMC0wK6ApoCeG
# JWh0dHA6Ly9zLnN5bWNiLmNvbS91bml2ZXJzYWwtcm9vdC5jcmwwEwYDVR0lBAww
# CgYIKwYBBQUHAwgwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTMwHQYDVR0OBBYEFK9j1sqjToVy4Ke8QfMpojh/gHViMB8GA1UdIwQYMBaA
# FLZ3+mlIR59TEtXC6gcydgfRlwcZMA0GCSqGSIb3DQEBCwUAA4IBAQB16rAt1TQZ
# XDJF/g7h1E+meMFv1+rd3E/zociBiPenjxXmQCmt5l30otlWZIRxMCrdHmEXZiBW
# BpgZjV1x8viXvAn9HJFHyeLojQP7zJAv1gpsTjPs1rSTyEyQY0g5QCHE3dZuiZg8
# tZiX6KkGtwnJj1NXQZAv4R5NTtzKEHhsQm7wtsX4YVxS9U72a433Snq+8839A9fZ
# 9gOoD+NT9wp17MZ1LqpmhQSZt/gGV+HGDvbor9rsmxgfqrnjOgC/zoqUywHbnsc4
# uw9Sq9HjlANgCk2g/idtFDL8P5dA4b+ZidvkORS92uTTw+orWrOVWFUEfcea7CMD
# jYUq0v+uqWGBMIIFSzCCBDOgAwIBAgIQe9Tlr7rMBz+hASMEIkFNEjANBgkqhkiG
# 9w0BAQsFADB3MQswCQYDVQQGEwJVUzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9y
# YXRpb24xHzAdBgNVBAsTFlN5bWFudGVjIFRydXN0IE5ldHdvcmsxKDAmBgNVBAMT
# H1N5bWFudGVjIFNIQTI1NiBUaW1lU3RhbXBpbmcgQ0EwHhcNMTcxMjIzMDAwMDAw
# WhcNMjkwMzIyMjM1OTU5WjCBgDELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFu
# dGVjIENvcnBvcmF0aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBOZXR3b3Jr
# MTEwLwYDVQQDEyhTeW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIFNpZ25lciAt
# IEczMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArw6Kqvjcv2l7VBdx
# Rwm9jTyB+HQVd2eQnP3eTgKeS3b25TY+ZdUkIG0w+d0dg+k/J0ozTm0WiuSNQI0i
# qr6nCxvSB7Y8tRokKPgbclE9yAmIJgg6+fpDI3VHcAyzX1uPCB1ySFdlTa8CPED3
# 9N0yOJM/5Sym81kjy4DeE035EMmqChhsVWFX0fECLMS1q/JsI9KfDQ8ZbK2FYmn9
# ToXBilIxq1vYyXRS41dsIr9Vf2/KBqs/SrcidmXs7DbylpWBJiz9u5iqATjTryVA
# mwlT8ClXhVhe6oVIQSGH5d600yaye0BTWHmOUjEGTZQDRcTOPAPstwDyOiLFtG/l
# 77CKmwIDAQABo4IBxzCCAcMwDAYDVR0TAQH/BAIwADBmBgNVHSAEXzBdMFsGC2CG
# SAGG+EUBBxcDMEwwIwYIKwYBBQUHAgEWF2h0dHBzOi8vZC5zeW1jYi5jb20vY3Bz
# MCUGCCsGAQUFBwICMBkaF2h0dHBzOi8vZC5zeW1jYi5jb20vcnBhMEAGA1UdHwQ5
# MDcwNaAzoDGGL2h0dHA6Ly90cy1jcmwud3Muc3ltYW50ZWMuY29tL3NoYTI1Ni10
# c3MtY2EuY3JsMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDB3BggrBgEFBQcBAQRrMGkwKgYIKwYBBQUHMAGGHmh0dHA6Ly90cy1vY3NwLndz
# LnN5bWFudGVjLmNvbTA7BggrBgEFBQcwAoYvaHR0cDovL3RzLWFpYS53cy5zeW1h
# bnRlYy5jb20vc2hhMjU2LXRzcy1jYS5jZXIwKAYDVR0RBCEwH6QdMBsxGTAXBgNV
# BAMTEFRpbWVTdGFtcC0yMDQ4LTYwHQYDVR0OBBYEFKUTAamfhcwbbhYeXzsxqnk2
# AHsdMB8GA1UdIwQYMBaAFK9j1sqjToVy4Ke8QfMpojh/gHViMA0GCSqGSIb3DQEB
# CwUAA4IBAQBGnq/wuKJfoplIz6gnSyHNsrmmcnBjL+NVKXs5Rk7nfmUGWIu8V4qS
# DQjYELo2JPoKe/s702K/SpQV5oLbilRt/yj+Z89xP+YzCdmiWRD0Hkr+Zcze1Gvj
# Uil1AEorpczLm+ipTfe0F1mSQcO3P4bm9sB/RDxGXBda46Q71Wkm1SF94YBnfmKs
# t04uFZrlnCOvWxHqcalB+Q15OKmhDc+0sdo+mnrHIsV0zd9HCYbE/JElshuW6YUI
# 6N3qdGBuYKVWeg3IRFjc5vlIFJ7lv94AvXexmBRyFCTfxxEsHwA/w0sUxmcczB4G
# o5BfXFSLPuMzW4IPxbeGAk5xn+lmRT92MYICWjCCAlYCAQEwgYswdzELMAkGA1UE
# BhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMR8wHQYDVQQLExZT
# eW1hbnRlYyBUcnVzdCBOZXR3b3JrMSgwJgYDVQQDEx9TeW1hbnRlYyBTSEEyNTYg
# VGltZVN0YW1waW5nIENBAhB71OWvuswHP6EBIwQiQU0SMAsGCWCGSAFlAwQCAaCB
# pDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI0
# MDIyNzIyNDYwMlowLwYJKoZIhvcNAQkEMSIEIOoQJgHgNgFLMjaZkw6WkeTcHBK1
# 2l5iKHHyWm2de1DPMDcGCyqGSIb3DQEJEAIvMSgwJjAkMCIEIMR0znYAfQI5Tg2l
# 5N58FMaA+eKCATz+9lPvXbcf32H4MAsGCSqGSIb3DQEBAQSCAQBsqqiehoeXZfgr
# aUXK2vh8ZTXvazc9NY2CSjdx/npFUcqRSOwzUZ4c+bYlUEnKZscodiRvF+ptTOph
# +yEkq9yL+lzNIWeP898kMao78RFkIOmJ0t3PrjPC5IODaDPpgZXpDSjZByePq7Jz
# aaeugir1hGqW/qzDfeMlwRqx9UKM3fnnzz+PkV+rtzkwSCiOY5rHqO+Xrd9PdrFJ
# ttEMo4Sq4tMlwrvAVC8OssgcPunKH27uFgRYvKpSZFsye3qTXYDwBlihCqY9KmwD
# 5bwB5sbBT8XBKFQ7uh/Ojl3sxFXz50p3VYrVtVbEzQ55PR0owhfsdJ9c4j9MLRr+
# C3E5DP61
# SIG # End signature block
