---
name: ni-crio-provision
description: >-
  Provision a National Instruments cRIO over its USB device port from
  Windows. Use when the user mentions provisioning a cRIO, installing
  NI-RIO or CompactRIO software on a controller, USB SSH to 172.22.11.2,
  or running tools/provision-crio.ps1 from an agent.
---

# Provision an NI cRIO

Run `tools/provision-crio.ps1`. Do not reimplement USB discovery, opkg, or NI Package Manager.

The program is that script. This skill is how an agent runs it. Deploy both files together. The script must stay at `tools/provision-crio.ps1` relative to the repo root.

## Do not

- Install NI-RIO IO Scan (`ni-crio-ioscan` or any package whose name contains `ioscan`). On this generation it blocks bitfile download.
- Tell the user to flip a SAFE MODE DIP switch. This chassis has none. Safe mode is RESET held at least 5 seconds.
- Put the SSH password on a command line. Set `CRIO_SSH_PASSWORD` in the process environment. An empty value is the default blank `admin` password. Remove the variable when the run finishes. Never print the value.
- Pass `-InstallMissing` or `-AssumeYes` before the person agrees in this conversation.
- Pass `-Reboot` before the person agrees to reboot the controller.

## Ask, then run once

The script prompts on the console. An agent has no console for those prompts. Ask in chat, then one non-interactive run.

Ask only what the person has not already chosen:

1. Feed version. List the directory names under `C:/Program Files/National Instruments/RT Feeds`.
2. LabVIEW Real-Time year, or drivers only. Drivers only is `-LabviewYear none`.
3. Extra package names, or none. CompactRIO Support (`ni-crio`), NI-RIO (`ni-rio`), and NI-RIO Server (`ni-rio-server`) are always installed.
4. Whether to install missing host software. Tell the person that some NI software is required to provision the cRIO, list what is missing, then ask if it is OK to install it. That software is NI Package Manager when it is missing, then NI-USBLAN, NI CompactRIO, NI-RIO, NI Controller Driver, and the matching RT feed. Also ask about the OpenSSH Client when it is missing.
5. Whether to reboot the controller after install.
6. SSH user (default `admin`) and password. Enter means blank.

The USB device port is the type-B port. The controller answers at `172.22.11.2`. The host NI-USBLAN adapter should be `172.22.11.1` with DHCP on. Confirm the cable and power before the run. This tool does not use the Ethernet address.

```powershell
$env:CRIO_SSH_PASSWORD = ""
try {
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/provision-crio.ps1 `
    -FeedVersion 26.8.0 `
    -LabviewYear none `
    -Package ni-visa `
    -InstallMissing `
    -AssumeYes
}
finally {
  Remove-Item Env:CRIO_SSH_PASSWORD -ErrorAction SilentlyContinue
}
```

Omit `-Package` when there are no extras. Repeat `-Package` or pass a comma-separated list for more than one. Add `-Reboot` only after the person agrees. `-InstallMissing` installs missing host software without a second console prompt. `-AssumeYes` skips the final install confirmation and does not reboot by itself.

If NI Package Manager is missing, the script asks to install it. With `-InstallMissing`, that question was already answered in chat, so the script downloads NI Package Manager 2026 Q4 from ni.com and installs it. Windows still asks for administrator approval. If the person says no, stop. A restart may be required before the driver packages can be installed.

## What the run does

1. If NI Package Manager is missing, asks to install it, then checks the other host packages. With `-InstallMissing`, installs anything missing after Windows asks for administrator approval.
2. Pings `172.22.11.2` and opens SSH.
3. Serves the selected feed over that USB link.
4. Shows the opkg plan, then installs the driver set and any extra packages.
5. Removes IO Scan if this install pulled it in and it was not already there.
6. Reboots only when `-Reboot` was passed, then checks SSH again.

## Check the tool

Before the first provision on a PC, or after editing the script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/provision-crio.ps1 -SelfTest
```

Success is the line `Self-test passed.` The self-test does not contact the controller.

## Report

Tell the person:

- Which host packages were already present, and which were installed
- SSH result, host name, and kernel line
- Feed version and the package names sent to opkg
- Whether the controller was rebooted, and whether `/dev/ni` or the kernel modules were present afterward

Bitstream work is outside this repository. Do not use this skill to compile a bitstream.
