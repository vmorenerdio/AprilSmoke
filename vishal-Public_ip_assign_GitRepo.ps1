<#
.SYNOPSIS
    Nerdio scripted action: Assign a Public IP address to an AVD session host's NIC.

.DESCRIPTION
    Written to run as the "custom" body of a Nerdio (NME/NMW) VM-scoped Azure Runbook
    scripted action — by the time this code executes, Nerdio has already:
      - Connected to Azure using the account's service connection
      - Set the Az context to the correct subscription
      - Made the target VM's name/resource group available as variables

    Uses Nerdio's documented built-in variables for Azure Runbook scripted actions:
    $AzureVMName and $AzureResourceGroupName (confirmed from Nerdio's Scripted
    Actions: Azure Runbooks help article). These are populated automatically when
    the scripted action is associated with a VM — no need to pass them in yourself.

.NOTES
    - Explicitly requests -Sku Standard. Basic-SKU public IPs were blocked from
      creation starting March 2025 and fully retired September 30, 2025 — any script
      still defaulting to Basic (or omitting -Sku, which used to default to Basic)
      will fail the create call outright.
    - Standard SKU public IPs are closed to inbound traffic by default. If you need
      inbound connectivity (not just an outbound-capable public IP), attach an NSG
      rule allowing the traffic you need — this script does not do that for you.
    - Deliberately avoids -ResourceId on Get-AzNetworkInterface / Get-AzPublicIpAddress
      / Get-AzVirtualNetworkSubnetConfig, since -ResourceId parameter sets were added
      to some of these cmdlets in later Az.Network releases than others. Using
      -Name/-ResourceGroupName instead (parsed from the resource ID string) works
      across every Az.Network version, avoiding "parameter cannot be found" errors
      tied to whatever version is actually loaded in a given Automation Account.
    - Every step throws on failure with -ErrorAction Stop and a final catch block
      that reports $_.Exception.Message, so a failure here will show you the real
      Azure error instead of a generic message.
    - Idempotent: if the NIC already has a public IP, it reports it and exits
      cleanly instead of creating a duplicate.
#>

# ---- Variables Nerdio provides for a VM-scoped scripted action ----
# These are Nerdio's documented built-in names; leave as-is.
$AzureVMName = $AzureVMName
$AzureRGName = $AzureResourceGroupName

# ---- Configurable ----
$PipSkuName    = "Standard"   # Basic is retired — do not change without a specific reason
$PipAllocation = "Static"     # Standard SKU requires Static allocation
$PipZone       = $null        # e.g. @("1") for a specific zone, or $null for no zone pinning

# Parses an Azure resource ID into its Name and ResourceGroupName, so we can call
# cmdlets with -Name/-ResourceGroupName instead of -ResourceId (broader version support).
function Get-NameAndRGFromResourceId {
    param([Parameter(Mandatory)][string]$ResourceId)
    if ($ResourceId -match '/resourceGroups/([^/]+)/.*/([^/]+)$') {
        return [pscustomobject]@{
            ResourceGroupName = $Matches[1]
            Name              = $Matches[2]
        }
    }
    throw "Could not parse resource ID: $ResourceId"
}

try {
    Write-Output "Looking up VM '$AzureVMName' in resource group '$AzureRGName'..."
    $vm = Get-AzVM -ResourceGroupName $AzureRGName -Name $AzureVMName -ErrorAction Stop

    $nicId   = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $nicInfo = Get-NameAndRGFromResourceId -ResourceId $nicId
    $nic     = Get-AzNetworkInterface -Name $nicInfo.Name -ResourceGroupName $nicInfo.ResourceGroupName -ErrorAction Stop
    $ipConfig = $nic.IpConfigurations[0]

    if ($ipConfig.PublicIpAddress) {
        Write-Output "NIC already has a public IP associated: $($ipConfig.PublicIpAddress.Id)"
        $pipInfo = Get-NameAndRGFromResourceId -ResourceId $ipConfig.PublicIpAddress.Id
        $existingPip = Get-AzPublicIpAddress -Name $pipInfo.Name -ResourceGroupName $pipInfo.ResourceGroupName -ErrorAction Stop
        Write-Output "Existing public IP address: $($existingPip.IpAddress)"
        return
    }

    Write-Output "No public IP currently associated. Creating a new one..."
    $pipName = "$AzureVMName-pip"

    $pipParams = @{
        ResourceGroupName = $AzureRGName
        Location          = $vm.Location
        Name              = $pipName
        AllocationMethod  = $PipAllocation
        Sku               = $PipSkuName
        ErrorAction       = "Stop"
    }
    if ($PipZone) { $pipParams["Zone"] = $PipZone }

    $pip = New-AzPublicIpAddress @pipParams
    Write-Output "Created public IP '$pipName'."

    Write-Output "Associating public IP with NIC '$($nic.Name)'..."
    # Reuse the NIC's existing subnet reference directly -- no need to re-fetch it,
    # which sidesteps another cmdlet whose -ResourceId support varies by version.
    Set-AzNetworkInterfaceIpConfig `
        -NetworkInterface $nic `
        -Name $ipConfig.Name `
        -PublicIpAddress $pip `
        -Subnet $ipConfig.Subnet `
        -ErrorAction Stop | Out-Null

    Write-Output "Applying NIC changes..."
    Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop | Out-Null

    Write-Output "Verifying assignment..."
    $verifyNic   = Get-AzNetworkInterface -Name $nicInfo.Name -ResourceGroupName $nicInfo.ResourceGroupName -ErrorAction Stop
    $verifyPipId = $verifyNic.IpConfigurations[0].PublicIpAddress.Id

    if ($verifyPipId) {
        $verifyPipInfo = Get-NameAndRGFromResourceId -ResourceId $verifyPipId
        $verifyPip = Get-AzPublicIpAddress -Name $verifyPipInfo.Name -ResourceGroupName $verifyPipInfo.ResourceGroupName -ErrorAction Stop
        Write-Output "SUCCESS: VM '$AzureVMName' now has public IP $($verifyPip.IpAddress)"
    }
    else {
        throw "Verification failed: NIC has no public IP after the update."
    }
}
catch {
    Write-Error "ERROR: VM was not assigned a public IP address. Details: $($_.Exception.Message)"
    throw
}
