#!/usr/bin/env python3
"""yaml-get.py — read a top-level key from one of our simple YAML files.

Usage:
    python3 scripts/yaml-get.py [--no-yaml] <file.yml> <key> [default]

PyYAML is used when available. A built-in parser is always kept as a fallback
so the build never silently returns empty strings on a minimal runner.
"""

import sys

EMPTY_HASH_PLACEHOLDER = None  # no-op marker kept for clarity; not used here


def _strip_comment(value):
    """Remove an inline # comment that is outside quotes."""
    quote = None
    for i, ch in enumerate(value):
        if ch in ("'", '"'):
            if quote is None:
                quote = ch
            elif quote == ch:
                quote = None
        elif ch == "#" and quote is None and (i == 0 or value[i - 1].isspace()):
            return value[:i]
    return value


def simple_parse(path, key, default):
    """Parse a 'key: value' line. Our build YAMLs are all flat key/value maps."""
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#") or line.startswith("-"):
                    continue
                if ":" not in line:
                    continue
                k, v = line.split(":", 1)
                if k.strip() != key:
                    continue
                v = _strip_comment(v.strip()).strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    quote = v[0]
                    v = v[1:-1]
                    if quote == '"':
                        v = v.replace("\\\\", "\\").replace('\\"', '"')
                return v
    except OSError:
        pass
    return default


def parse(path, key, default, force_fallback=False):
    if not force_fallback:
        try:
            import yaml  # type: ignore
        except ImportError:
            yaml = None
        if yaml is not None:
            try:
                with open(path, encoding="utf-8") as handle:
                    data = yaml.safe_load(handle)
                if isinstance(data, dict):
                    val = data.get(key, default)
                    return default if val is None else val
            except Exception:
                pass  # fall through to the dependency-free parser
    return simple_parse(path, key, default)


def main(argv):
    force_fallback = False
    if argv and argv[0] == "--no-yaml":
        force_fallback = True
        argv = argv[1:]
    if len(argv) < 2:
        print(
            "Usage: yaml-get.py [--no-yaml] <file.yml> <key> [default]",
            file=sys.stderr,
        )
        return 2
    path, key = argv[0], argv[1]
    default = argv[2] if len(argv) > 2 else ""
    print(parse(path, key, default, force_fallback))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
