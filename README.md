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
python cli.py autoshow
python cli.py snap
python cli.py bot -d -v

# PowerShell
.\cli.ps1 bot
.\cli.ps1 purge
.\cli.ps1 autoshow
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

```powershell
# by name -- resolves to workflows/bot.yaml
python cli.py bot

# by path -- any YAML file
python cli.py C:\Users\me\my_custom.yaml
```

### Steps

| Step                                                                 | Description                                                   |
| -------------------------------------------------------------------- | ------------------------------------------------------------- |
| `press: enter`                                                       | Send a single key                                             |
| `repeat: {key: down, times: 4}`                                      | Send a key N times                                            |
| `wait:`                                                              | Sleep `reframe_interval`. Explicit: `wait: 2.0`               |
| `countdown: 3`                                                       | Visible countdown before proceeding (default 3s)              |
| `wait_on: {template: home_menu}`                                     | Poll screen until a template condition succeeds               |
| `scroll_to: target`                                                  | Scroll the car grid to the first matching template column     |
| `purge: {template: target, marker: delete_marker, brand_new: false}` | Delete matching cars                                          |
| `snap:`                                                              | Capture frame + write slot and brand-new crops to dump folder |
| `detect: {templates: {start: enter, ...}}`                           | Match templates and press the mapped key on hit               |

### Action arguments

| Action      | Required                                               | Optional             |
| ----------- | ------------------------------------------------------ | -------------------- |
| `press`     | key name as value                                      | none                 |
| `repeat`    | `key`, `times`                                         | none                 |
| `wait`      | none                                                   | seconds as value     |
| `countdown` | none                                                   | seconds as value     |
| `wait_on`   | `template`                                             | `timeout`, `on_miss` |
| `scroll_to` | single template name as value                          | none                 |
| `purge`     | `template`, `brand_new` (`true`, `false`, or `bypass`) | `marker`             |
| `snap`      | none                                                   | none                 |
| `detect`    | `templates`                                            | `count`              |

`wait_on.template` accepts a single template name or an explicit boolean expression. `scroll_to`, `purge.template`, and `purge.marker` accept single template names only.

`detect.count` allows that many key presses for the first entry under `templates`; the next match for that entry stops before pressing its key.

For template expressions, lists are only valid under `all` or `any`; bare `template: [a, b]` is intentionally invalid.

```yaml
- press: enter

- repeat:
    key: down
    times: 4

- wait:
- wait: 2.0

- countdown: 3
```

```yaml
- wait_on:
    template: a
- wait_on:
    template:
      any: [a, b]
- wait_on:
    template:
      all:
        - a
        - any: [b, c]
```

```yaml
- scroll_to: target

- purge:
    template: target
    marker: delete_marker
    brand_new: false

- purge:
    template: target
    brand_new: bypass

- snap:

- detect:
    templates:
      start: enter
      result: x
      confirm: enter

- detect:
    count: 100
    templates:
      start: enter
      result: x
      confirm: enter
```
