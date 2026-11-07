"""Edit Finder icon positions in a volume's .DS_Store.

usage: dmg_layout.py <path/.DS_Store> [<old name>=><new name>] [<name>=<x>,<y>] ...

"old=>new" gives an item's icon position to an item of another name (the
replacement of a file on the template); "name=x,y" places an icon. Positions
are icon centres in window points, as Finder stores them (Iloc). Every other
record (window bounds, view options, background picture) is kept as it is.
"""
import sys

import ds_store.store
from ds_store import DSStore

# Only decode icon positions; everything else is copied through as raw bytes.
for _code in list(ds_store.store.codecs):
    if _code != b"Iloc":
        del ds_store.store.codecs[_code]


def main():
    path, specs = sys.argv[1], sys.argv[2:]
    with DSStore.open(path, "r+") as d:
        for spec in specs:
            if "=>" in spec:
                old, new = spec.split("=>", 1)
                pos = None
                for e in d:
                    if e.filename == old and e.code == b"Iloc":
                        pos = e.value
                if pos is None:
                    sys.exit(f"{old}: no icon position in {path}")
                d[new]["Iloc"] = pos
                print(f"{new}: ({pos[0]}, {pos[1]}) from {old}")
            else:
                name, xy = spec.rsplit("=", 1)
                x, y = (int(v) for v in xy.split(","))
                d[name]["Iloc"] = (x, y)
                print(f"{name}: ({x}, {y})")


if __name__ == "__main__":
    main()
