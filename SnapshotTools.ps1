<#
Tools for handling snapshots in an automated fashion
Created by: Jonathan Bonde
Created date: 8/15/2019
Version: 0.1
Updated date: 
More updates to follow.  For suggestions, contact CatchJB@gmail.com
#>

# Setup global variables:
Write-Host 'Enter Admin Login Username in UPN or Domain\ format: ' -ForegroundColor Green -NoNewline
$user = Read-Host 
$vccred = Get-Credential -UserName $user -Message 'Enter Admin ID Password:'
$vcenter = 'vCenter Address Here'

#Connect to vCenter
Connect-VIServer -Server $vcenter -Credential $vccred

function Get-SnapshotReport {
    # This function will check your environment for any snapshots over 5 days old and report on several characteristics of that snapshot
    $snapReport = @()
    $snaps5 = get-view -ViewType VirtualMachine -Filter @{"snapshot" = ""} -Property Name | ForEach-Object {get-vm -id $_.MoRef | get-snapshot | Where-Object {$_.Created -le (Get-Date).AddDays(-3)}}
    foreach ($snap in $snaps5) {
        $snapevent = Get-VIEvent -Entity $snap.VM -Types Info -Finish $snap.Created -MaxSamples 1 | Where-Object {$_.FullFormattedMessage -imatch 'Task: Create virtual machine snapshot'}
        $snapInfo = {} | Select-Object VMName, SnapName, Created, Creator, SizeGB, vCenter
        $snapInfo.VMName = $snap.VM
        $snapInfo.SnapName = $snap.Name
        $snapInfo.Created = $snap.Created.DateTime
        $snapInfo.Creator = $snapevent.UserName
        $snapInfo.SizeGB = [math]::round($snap.SizeGB,2)
        $snapInfo.vCenter = (get-vm $snap.VM).ExtensionData.Client.Serviceurl.split('/')[2]
        $snapReport += $snapInfo
    }
    $snapReport = $snapReport | Sort-Object VMName | Format-Table -AutoSize
    $snapReport
}


function Send-SnapEmail {
    # This function will find snapshots 4 days old, extract the snapshot creator and that persons email address, then send the person an email stating they 
    # have 24 hours to remediate the snapshot, or it will be automatically deleted.
    $snaps4 = get-view -ViewType VirtualMachine -Filter @{"snapshot" = ""} -Property Name | ForEach-Object {get-vm -id $_.MoRef | get-snapshot | Where-Object {$_.Created -le (Get-Date).AddDays(-3)}}
    # General email settings
    $smtp = "Enter SMTP Mail Relay Here"
    $emailSender = "Give Email Address or DL here"
    # Body of the email explaining the Snapshot Policy
    $body = @"
This is a courtesy email to let you know the snapshot of $vmname created by account $snapUser is four days old and will be deleted in 24 hours. 
"@ 

    foreach ($snap in $snaps4) {
        $snapevent = Get-VIEvent -Entity $snap.VM -Types Info -Finish $snap.Created -MaxSamples 1 | Where-Object {$_.FullFormattedMessage -imatch 'Task: Create virtual machine snapshot'}
        foreach ($snapCreator in $snapevent) {
            $vmName = $snap.VM
            $snapDate = $snap.Created
            # This bit of code is to find the username, which in vCenter typically shows as DOMAIN\UserName.  So this splits on the \ and chooses the second object (username)
            $snapUser = $snapCreator.UserName.split('\')[1]
            # The place I developed this placed a three letter ending on admin accounts, this code just takes that off so we can extrapolate the email address below it
            # if this isn't needed, just delete the actualUser variable and adjust code below
            $actualUser = $snapUser.Substring(0,$snapUser.Length-3)
            $snapMail = (Get-ADUser $actualUser -Properties mail).mail
            $emailTo = @($snapmail, "Any other recipients you may wish to tell")
            $backupTeam = "Enter your backup teams DL here or delete this"
            $backupSubject = "Backup generated snapshot of $vmName on $snapDate"
            $subject = "Your snapshot of $vmName taken on $snapDate"
            if ($snapUser -like '*BackupServiceAccount*' -or $snap.Name -like '*BackupSnapArchive*') {
                Write-Host "Snapshot Creator is the Backup service account"
                # If this block evaluates to true then the email should be sent to $backupTeam.  If that DL changes, make sure to change the $backupTeam variable
                Send-MailMessage -From $emailSender -To $backupTeam -SmtpServer $smtp -Subject $backupSubject -Body $body
                Write-Host "Email has been submitted to $smtp"
            }
            elseif ($snapUser -notlike '*BackupServiceAccount*' -or $snap.Name -notlike "*BackupSnapArchive*") {
                Write-Host "Sending email to $emailTo regarding snapshot of $snapInfo.VM"
                # If this block evaluates to true then the email should be sent to the email of the user who created the snapshot.
                Send-MailMessage -From $emailSender -To $emailTo -SmtpServer $smtp -Subject $subject -Body $body
                Write-Host "Email has been submitted to $smtp"
            }
        }
    }
}

function Remove-Snaps5DaysOld {
    # This function will go about removing the snapshots 5 days old
    $snap5 = get-view -ViewType VirtualMachine -Filter @{"snapshot" = ""} -Property Name | ForEach-Object {get-vm -id $_.MoRef | get-snapshot | Where-Object {$_.vm.name -eq 'rm_test_2'}} 
    foreach ($snap in $snap5) {
        $snapevent = Get-VIEvent -Entity $snap.VM -Types Info -Finish $snap.Created -MaxSamples 1 | Where-Object {$_.FullFormattedMessage -imatch 'Task: Create virtual machine snapshot'}
        foreach ($snapCreator in $snapevent) { 
        $vmName = $snap.VM.Name
        $snapID = $snap.Id
        $snapDate = $snap.Created
        # This bit of code is to find the username, which in vCenter typically shows as DOMAIN\UserName.  So this splits on the \ and chooses the second object (username)
        $snapUser = $snapCreator.UserName.split('\')[1]
        $snapexceptions = Get-Content #<the location of your exceptions file, if you have one>
        if ($snapuser -like '*Any service account or user you account you may wish to exclude from automatic snapshot deletion*' -or $snapexceptions -contains $vmName) {
            Write-Host "Snapshot of $vmname created by $snapuser or on the exceptions list, not deleting this snapshot"
            }
        elseif ($snapuser -notlike '*Any service account or user you account you may wish to exclude from automatic snapshot deletion*' -or $snapexceptions -notcontains $vmName) {
            # This is where the meat of the snapshot remediation is done.  Note the -whatif.  If you want this to work, replace with -confirm:$false
            Write-Host "Now removing Snapshot $snapid of $vmname created on $snapDate"
            $timeout = 1800 ## seconds = 30 minutes - this should be plenty of time to delete most snapshots
            $frequency = 30 ## seconds - check every 30 seconds for this task
            ## Start a timer
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $snapremoval = Get-Snapshot -VM $vmName -Id $snapID | Remove-Snapshot -RemoveChildren -whatif
            # placing the remove-snapshot in a variable like above actually captures the task that is created for this job.  Below we capitalize on that to track the task
            $task = $snapremoval.Id
            try {
                while ((Get-Task -Id $task).PercentComplete -ne "100") {
                    Write-Host "Waiting for $task for VM $vmname to complete snapshot"
                    if ($timer.Elapsed.TotalSeconds -ge $timeout) {
                        throw "Waited 30 minutes and $vmname snapshot still not removed, VMware team will have to check to make sure the snapshot was deleted or manually remediate if not" 
                        }
                    Start-Sleep -Seconds $frequency
                }
                # When the above loop is completed, stop the timer
                $timer.Stop()
                }
            catch {
                Write-Host "Snapshot removal of $vmName took too long, no longer monitoring status."
                }
            finally {
                if ((Get-Task -Id $task).State -eq "Success") {
                    Write-Host "Removal of snapshot for $vmName has completed successfully." -ForegroundColor Green
                    }
                elseif ((Get-Task -Id $task).State -ne "Success") {
                    Write-Host "Removal of snapshot for $vmName has ran more than 30 minutes without completion. VMware Team may have to manually remediate to resolve this" -ForegroundColor Magenta
                    }
                }
            }
        }
    }
}

# Logging start of task
$taskDate = Get-Date -Format MMddyyyy
$logFile = "<your favorite logging location>Snapshot_Log_$(Get-Date -f MMddyyyy).log"
Start-Transcript -Path $logFile

Write-Host "Beginning of snapshot report for $taskDate"
Get-SnapshotReport

Start-Sleep 180

Send-SnapEmail

Start-Sleep 180

Remove-Snaps5DaysOld

Start-Sleep 180

Get-SnapshotReport

Write-Host "End of snapshot report for $taskDate"

Stop-Transcript