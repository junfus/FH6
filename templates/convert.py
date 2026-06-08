# RUN: python convert.py --height 2160 --file foo
# Reads foo.png from this folder, scales to 720p, outputs t_foo.png, appends threshold.
import argparse
import sys
from pathlib import Path
import cv2

VALID_HEIGHTS = (720, 900, 1080, 1440, 2160)


def main():
    parser = argparse.ArgumentParser(
        description="Scale a raw PNG to 720p template", add_help=False
    )
    parser.add_argument("-h", "--height", type=int, required=True)
    parser.add_argument("-f", "--file", type=str, required=True)
    parser.add_argument("-t", "--threshold", type=float, default=0.85)
    args = parser.parse_args()

    height = args.height
    name = args.file
    threshold = args.threshold

    if height not in VALID_HEIGHTS:
        print(
            f"Invalid height {height}. Valid: {', '.join(str(h) for h in VALID_HEIGHTS)}",
            file=sys.stderr,
        )
        sys.exit(1)

    src_path = Path(__file__).resolve().parent / f"{name}.png"
    if not src_path.exists():
        print(f"File not found: {src_path}", file=sys.stderr)
        sys.exit(1)

    scale = 720.0 / height
    print(f"Loading {name}.png (source height={height}, scale={scale:.4f})")

    img = cv2.imread(str(src_path), cv2.IMREAD_UNCHANGED)
    src_h, src_w = img.shape[:2]
    print(f"Source image: {src_w}x{src_h}")

    if abs(scale - 1.0) < 0.001:
        scaled = img
    else:
        new_w = max(1, round(src_w * scale))
        new_h = max(1, round(src_h * scale))
        print(f"Scaling to {new_w}x{new_h}")
        scaled = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_CUBIC)

    out_path = Path(__file__).resolve().parent / f"t_{name}.png"
    cv2.imwrite(str(out_path), scaled)
    size_kb = out_path.stat().st_size / 1024
    print(f"Saved: t_{name}.png ({size_kb:.1f} KB)")

    # append threshold
    yaml_path = Path(__file__).resolve().parent / "thresholds.yaml"
    if yaml_path.exists():
        content = yaml_path.read_text()
    else:
        content = ""

    import re

    if re.search(rf"(?m)^{re.escape(name)}:", content):
        print(f"Threshold for '{name}' already exists in thresholds.yaml, skipping")
    else:
        trimmed = content.rstrip()
        entry = f"{name}: {threshold:.2f}"
        yaml_path.write_text(f"{trimmed}\n{entry}\n", newline="\n")
        print(f"Added '{entry}' to thresholds.yaml")


if __name__ == "__main__":
    main()
