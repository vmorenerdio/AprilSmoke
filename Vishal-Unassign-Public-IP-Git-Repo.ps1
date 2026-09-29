#description: Removes and deletes the public IP address associated with each session host VM.
#tags: Nerdio
<#
Notes:
This script removes a Public IP from a VM's NIC and deletes the underlying Public IP
Azure resource.

This is the companion/undo script to the "Assign Public IP" script. Because a Standard SKU
static Public IP is billed whether or not it is attached to anything, simply disassociating
it would leave an orphaned resource that keeps incurring cost. This script therefore:
  1. Disassociates the Public IP from the VM's NIC
  2. Deletes the Public IP resource itself

Important: VM must have one NIC (default setup). If you want to keep the Public IP resource
around for future re-use instead of deleting it, remove the final Remove-AzPublicIpAddress
step below.
#>

# Ensure context is using correct subscription
Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null

# Query for Azure VM object using $AzureVMName parameter, pass into $AzVM
$AzVM = Get-AzVM -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName

# Query for NIC attached to VM, pass into $NIC
$NIC = Get-AzNetworkInterface -resourceID $AzVM.NetworkProfile.NetworkInterfaces.Id

# Detect if a Public IP is actually associated with the VM
if(!$NIC.IpConfigurations.PublicIPAddress)
{
    Write-Output "INFO: This VM has no Public IP Address associated. No action needed, stopping script."
    exit
}

# Capture the Public IP resource so we can delete it after disassociating
$PubIPId = $NIC.IpConfigurations.PublicIPAddress.Id
$PubIPName = ($PubIPId -split '/')[-1]
$PubIP = Get-AzPublicIPAddress -Name $PubIPName -ResourceGroupName $AzVM.ResourceGroupName

# Remove the Public IP association from the NIC
Write-Output "INFO: Disassociating Public IP from VM"
$NIC.IpConfigurations[0].PublicIPAddress = $null
$NIC | Set-AzNetworkInterfaceIpConfig -Name $NIC.IpConfigurations.Name -Subnet $NIC.IpConfigurations.Subnet | Out-Null

# Set the interface to finalize change
Write-Output "INFO: Setting NIC Interface to finalize changes. . ."
$NIC | Set-AzNetworkInterface | Out-Null

# Delete the now-orphaned Public IP resource
Write-Output "INFO: Deleting Public IP resource '$PubIPName'"
$PubIP | Remove-AzPublicIpAddress -Force -ErrorAction Stop

# Verify
$VerifyNIC = Get-AzNetworkInterface -resourceID $AzVM.NetworkProfile.NetworkInterfaces.Id
$VerifyPubIP = Get-AzPublicIPAddress -Name $PubIPName -ResourceGroupName $AzVM.ResourceGroupName -ErrorAction SilentlyContinue

if(!$VerifyNIC.IpConfigurations.PublicIPAddress -and !$VerifyPubIP)
{
    Write-Output "INFO: Public IP has been unassigned and deleted successfully."
}
else {
    Write-Output 'ERROR: VM Public IP was not fully removed'
    Write-Error 'ERROR: VM Public IP was not fully removed' -ErrorAction Stop
}
