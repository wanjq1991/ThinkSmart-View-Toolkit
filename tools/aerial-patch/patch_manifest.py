#!/usr/bin/env python3
"""Patch attributes inside an APK's compiled AndroidManifest.xml.

Written for apps shipped as prebuilt APKs with no source available (Aerial in
this case), where the only way to change a manifest value is to edit the binary
AXML in place. Every supported edit rewrites an existing field of the same
width, so the manifest size -- and therefore every downstream offset -- stays
identical.

Commands
--------
    patch_manifest.py list  app.apk
    patch_manifest.py set-int app.apk out.apk activity screenOrientation 8
    patch_manifest.py set-str app.apk out.apk category name android.intent.category.LAUNCHER --index 0

Use --index when several elements match; the list output prints them in the
same order so the number can be verified before writing.
"""

import argparse
import sys
import zipfile

import axml


def collect(b, strings, element, attr):
    hits = []
    for name, attrs in axml.iter_elements(b, strings):
        if name != element:
            continue
        for a in attrs:
            if a["name"] == attr:
                hits.append(a)
    return hits


def print_list(path):
    b = axml.read_manifest(path)
    strings = axml.read_string_pool(b)
    print("# %s  (%d strings, %d bytes)" % (path, len(strings), len(b)))
    for name, attrs in axml.iter_elements(b, strings):
        if name not in ("activity", "activity-alias", "category", "uses-sdk"):
            continue
        label = name
        for a in attrs:
            if a["name"] == "name":
                label = "%s[%s]" % (name, a["raw"] or axml.describe_value(a, strings))
                break
        print("\n%s" % label)
        for a in attrs:
            print(
                "  %-24s @%-8s type=0x%02x  raw=%-40s value=%s"
                % (
                    a["name"],
                    hex(a["offset"]),
                    a["type"],
                    a["raw"] if a["raw"] is not None else "<none>",
                    axml.describe_value(a, strings),
                )
            )


def write_apk(src, dst, manifest):
    """Copy every entry, swapping only AndroidManifest.xml.

    The v1 signature entries are dropped because they are now invalid anyway;
    the APK has to be re-signed afterwards (see repack.sh).
    """
    with zipfile.ZipFile(src) as zin:
        with zipfile.ZipFile(dst, "w") as zout:
            for item in zin.infolist():
                if item.filename == "AndroidManifest.xml":
                    continue
                if item.filename.upper().startswith("META-INF/") and item.filename.upper().endswith(
                    (".SF", ".RSA", ".DSA", ".EC")
                ):
                    continue
                zout.writestr(item, zin.read(item.filename))
            info = zipfile.ZipInfo("AndroidManifest.xml")
            info.compress_type = zipfile.ZIP_DEFLATED
            zout.writestr(info, bytes(manifest))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="dump activity / category attributes")
    p_list.add_argument("apk")

    for name, help_text in (
        ("set-int", "write an integer into the typed value slot"),
        ("set-str", "repoint a string attribute to an existing pool string"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("apk")
        p.add_argument("out")
        p.add_argument("element")
        p.add_argument("attr")
        p.add_argument("value")
        p.add_argument("--index", type=int, default=None, help="which match to edit (default: require exactly one)")

    args = ap.parse_args()

    if args.cmd == "list":
        print_list(args.apk)
        return

    b = axml.read_manifest(args.apk)
    strings = axml.read_string_pool(b)
    hits = collect(b, strings, args.element, args.attr)
    if not hits:
        raise SystemExit("no <%s %s> found" % (args.element, args.attr))

    if args.index is None:
        if len(hits) != 1:
            raise SystemExit(
                "%d matches for <%s %s>; re-run with --index 0..%d"
                % (len(hits), args.element, args.attr, len(hits) - 1)
            )
        target = hits[0]
    else:
        if not 0 <= args.index < len(hits):
            raise SystemExit("--index out of range (0..%d)" % (len(hits) - 1))
        target = hits[args.index]

    before = axml.describe_value(target, strings)
    if args.cmd == "set-int":
        value = int(args.value, 0)
        axml.set_int(b, target, value)
        after = axml.describe_value(target, strings)
    else:
        axml.set_string(b, target, strings, args.value)
        after = axml.describe_value(target, strings)

    print("<%s %s> @%s: %r -> %r" % (args.element, args.attr, hex(target["offset"]), before, after))
    write_apk(args.apk, args.out, b)
    print("wrote %s" % args.out)


if __name__ == "__main__":
    sys.exit(main())
