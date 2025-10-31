import re
import sys
from pathlib import Path


UL_PATTERN = re.compile(r'<(/?)ul>')
LI_PATTERN = re.compile(r'<(/?)li>')


def convert_file(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    new_text = text
    new_text, _ = UL_PATTERN.subn(lambda m: f"<{m.group(1)}choices>", new_text)
    new_text, _ = LI_PATTERN.subn(lambda m: f"<{m.group(1)}choice>", new_text)

    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        return True
    return False


def iter_ptx_files(paths: list[Path]) -> list[Path]:
    if paths:
        files = [path for path in paths if path.suffix == ".ptx" and path.is_file()]
    else:
        files = [path for path in Path('.').rglob('*.ptx') if path.is_file()]
    return sorted(files)


def main() -> int:
    if len(sys.argv) > 1:
        files = iter_ptx_files([Path(arg) for arg in sys.argv[1:]])
    else:
        files = iter_ptx_files([])

    any_changed = False
    for path in files:
        if convert_file(path):
            print(f"Updated {path}")
            any_changed = True
    if not any_changed:
        print("No changes needed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
