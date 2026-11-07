"""Mark every bundle's version as the Universal 2 build.

usage: stamp_version.py <suffix> <path>...

For each Info.plist in the bundles under the given paths (apps, and the
frameworks and plug-ins inside them), appends <suffix> (such as "-U2B") to
CFBundleShortVersionString, and to that version where CFBundleGetInfoString
repeats it ("17.0.0 (720), (c) 2013 ..." becomes "17.0.0-U2B (720), ...").
CFBundleVersion stays as it is: it is a build number that updaters compare.
Plists already stamped are left alone.
"""
import os
import plistlib
import sys


def stamp(path, suffix):
    with open(path, "rb") as fh:
        data = fh.read()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
    try:
        p = plistlib.loads(data)
    except Exception as e:  # noqa: BLE001 - report and keep going
        print(f"skipped {path}: {e}")
        return
    ver = p.get("CFBundleShortVersionString")
    if not isinstance(ver, str) or not ver or ver.endswith(suffix):
        return
    p["CFBundleShortVersionString"] = ver + suffix
    info = p.get("CFBundleGetInfoString")
    if isinstance(info, str) and ver in info:
        p["CFBundleGetInfoString"] = info.replace(ver, ver + suffix, 1)
    with open(path, "wb") as fh:
        plistlib.dump(p, fh, fmt=fmt)
    print(f"{path}: {ver} -> {ver + suffix}")


def main():
    suffix, roots = sys.argv[1], sys.argv[2:]
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(d, x))]
            if os.path.basename(d) == "Contents" and "Info.plist" in files:
                stamp(os.path.join(d, "Info.plist"), suffix)
            elif "Info.plist" in files and os.path.basename(os.path.dirname(d)) == "Versions":
                stamp(os.path.join(d, "Info.plist"), suffix)
            elif "Info.plist" in files and os.path.basename(d) == "Resources":
                stamp(os.path.join(d, "Info.plist"), suffix)


if __name__ == "__main__":
    main()
