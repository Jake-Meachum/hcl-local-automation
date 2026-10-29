# HCL Local Automation Runner

Local-compute-first automation for **H3C Cloud Lab (HCL 5.10.3)** on Windows:
open a lab project, boot devices, push CLI configuration, run verifications and
produce a compact pass/fail report — **all inside one local script run**, so an
LLM/agent only needs **one tool call + one small report read** instead of
dozens of screenshot/click round-trips.

## Why

GUI-driven LLM automation is expensive: every click needs a screenshot, screenshots
cost image tokens, and repeated model round-trips add latency. This runner moves
waiting, retrying, parsing and assertion into a local PowerShell process:

| Step | Screenshot-driven agent | This runner |
|---|---|---|
| Open project | screenshots + clicks per step | local retry loop on known coordinates |
| Boot devices | poll screenshots | poll `HCL.log` for `create_telnet_server` lines |
| Configure | one tool call per command | whole plan over local TCP console, local echo validation |
| Verify | model reads screenshots | regex assertions -> PASS/FAIL, computed locally |
| Failures | model retries | local retries (console 240 s, boot 300 s) |

Result: one elevated invocation, one ~10-line summary.

## Files

| File | Purpose |
|---|---|
| `hcl-runner.ps1` | One-shot runner: open project -> start devices -> discover console ports -> configure -> verify/assert -> save -> compact reports |
| `elevated-automation.ps1` | GUI automation daemon (click / keys / paste / type / screenshot / list windows) for steps that truly need the GUI |
| `plan-example.json` | Configuration plan example (devices, commands, verify commands, assertions) |
| `本地算力优先-使用说明.md` | Chinese usage notes (token-saving design) |

## Requirements

- Windows 10/11, PowerShell 5.1
- H3C Cloud Lab **5.10.3** installed (default `C:\Program Files (x86)\HCL`)
- Administrator rights (HCL itself requires elevation)
- Scripts must be saved as **UTF-8 with BOM** (PowerShell 5.1 otherwise decodes
  non-ASCII as the ANSI code page and can mis-parse Chinese strings)

## Quick start

```powershell
# (elevated) plan = what to configure and what to assert
powershell -ExecutionPolicy Bypass -File hcl-runner.ps1 `
  -PlanFile  plan-example.json `
  -OutDir    .\out `
  -DryRun                     # validate plan only, no GUI

# real run
powershell -ExecutionPolicy Bypass -File hcl-runner.ps1 `
  -PlanFile  plan-example.json `
  -OutDir    .\out `
  -BootTimeoutSec 300 -ConsoleTimeoutSec 240
```

Outputs in `-OutDir`:

- `runner-summary.txt` — tiny summary the agent should read:
  ```
  success=True duration=241s errors=0
  SW1 PASS port=30001 checks=7/7 saved=True
  SW2 PASS port=30002 checks=4/4 saved=True
  ```
- `runner-report.md` / `runner-report.json` — full details (verify command outputs)
- `runner.log` — timestamped local log

## Plan format

```json
{
  "project": "C:\\\\path\\\\to\\\\hcl_333852328419.net",
  "devices": {
    "SW1": {
      "id": 1,
      "save": true,
      "commands": ["system-view", "sysname SW1", "..."],
      "verify": ["display ip interface brief", "display vlan"],
      "checks": ["192.168.10.1", "VLAN ID: 10"]
    }
  }
}
```

- `id`: HCL device id; switch console = `30000 + id`, discovered from the HCL log
- `commands`: sent in order, echo checked for `Unrecognized/Too many/Wrong parameter`
- `verify`: outputs captured verbatim into the reports
- `checks`: regexes evaluated **locally**; all must hit for PASS

## Options

| Switch | Effect |
|---|---|
| `-DryRun` | validate plan, write `runner-dryrun.json`, exit |
| `-NoGuiOpen` | fail instead of trying to open the project via GUI |
| `-SkipStart` | don't press "start all devices" |
| `-ForceConfigure` | re-apply commands even if `sysname` already matches |
| `-BootTimeoutSec` / `-ConsoleTimeoutSec` | boot / console-ready timeouts |

## Behaviour & safety notes

- Opening a project uses an **isolated project directory** under the workspace:
  existing HCL processes are stopped, the project is copied there, and
  `HCL.ini` `project_directory` is pointed at it and **restored** after opening.
- A single-instance lock (`runner.lock`, validated by command line) prevents two
  runners from deleting each other's project directory while devices boot.
- The runner creates the `backupFileNameDirqwertyuiop` directory HCL expects when
  booting devices.
- Designed for lab/education automation on your own machine. Not affiliated with
  H3C. Use at your own risk.

## License

MIT
