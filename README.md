# fh-cli

Forza Horizon 6 automation CLI. YAML-driven workflow engine with two implementations:

- **cli.py** -- Python (mss + pydirectinput, local play)
- **cli.ps1** -- PowerShell (System.Drawing + SendKeys, works over RDP)

Both share config, templates, and workflow YAML files.

## Setup

```powershell
# Python
.\setup-python.ps1

# PowerShell
.\setup-pwsh.ps1
```

## Run

```powershell
# Python
python cli.py bot
python cli.py purge
python cli.py snap
python cli.py bot -d -v

# PowerShell
.\cli.ps1 bot
.\cli.ps1 purge
.\cli.ps1 snap
.\cli.ps1 bot -Dump -Verbose
```

## Add a template

1. Take a screenshot at your resolution
2. Crop the region you want to match
3. Save as `templates/<name>.png`
4. Run the converter:
   ```
   python templates/convert.py --height 2160 --file <name>
   # or
   .\templates\convert.ps1 -Height 2160 -File <name>
   ```
5. The converter scales to 720p, saves `t_<name>.png`, and appends the threshold to `thresholds.yaml`

## Create a workflow

Create a YAML file in `workflows/` or any path. See `workflows/bot.yaml` for a minimal example, `workflows/autoshow.yaml` for a full cycle.

### Steps

| Step                            | Description                                                                                                          |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `press: enter`                  | Send a single key                                                                                                    |
| `repeat: {key: down, times: 4}` | Send a key N times                                                                                                   |
| `wait:`                         | Sleep `reframe_interval`. Explicit: `wait: 2.0`                                                                      |
| `countdown: 3`                  | Visible countdown before proceeding (default 3s)                                                                     |
| `wait_template: home_menu`      | Poll screen until a template matches. Supports `timeout` and `on_miss` (key to press each cycle if not matched)      |
| `scroll_to_target:`             | Scroll the car grid to find the first target badge column. Checks left edge for first page, right edge for last page |
| `purge_duplicates:`             | Scroll right through target columns, slice 4x3 grid, find rated non-new duplicates, delete them                      |
| `snap:`                         | Capture frame + slice 12 grid cells to dump folder                                                                   |
| `detect: {start: enter, ...}`   | Match screen against templates, press the mapped key on hit. For state-machine loops like wheelspin                  |
