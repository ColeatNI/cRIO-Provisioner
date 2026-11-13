# cRIO USB provision

Windows tool that provisions a National Instruments cRIO over the USB device port. CompactRIO Support, NI-RIO, and NI-RIO Server are installed on the controller. NI-RIO IO Scan is not installed.

This repository is only that tool and the Cursor skill that runs it.

## Run it

Connect the PC to the cRIO USB device port and power the controller. Then:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\provision-crio.ps1
```

The controller answers at `172.22.11.2`. The SSH user is `admin`. The default password is blank. Set `CRIO_SSH_PASSWORD` in the environment when a password is required. Do not put the password on the command line.

Check the script without contacting a controller:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\provision-crio.ps1 -SelfTest
```

Success is the line `Self-test passed.`

## Run it from an agent

Open this repository in Cursor. The skill is `.cursor/skills/ni-crio-provision/SKILL.md`. The agent runs `tools/provision-crio.ps1` from this folder.

## Required on the PC

- Windows
- NI Package Manager. If it is missing, the tool asks before installing it.
- The NI Linux Real-Time feed for the software version you select.

`tools/.crio-askpass.cmd` and `tools/.crio-known-hosts` are created during a run. They are not part of this repository.
