"""Minimal reader for Android's binary XML (AXML).

Only what is needed to locate and patch attribute records inside an already
compiled AndroidManifest.xml: the string pool, the element chunks and the
per-attribute address. Nothing is rebuilt, so the file size never changes --
which is what makes in-place patching of a signed APK possible at all.

Format reference: frameworks/base/libs/androidfw/include/androidfw/ResourceTypes.h
"""

import struct

RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_END_ELEMENT_TYPE = 0x0103

# android.util.TypedValue data types
TYPE_STRING = 0x03
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_INT_BOOLEAN = 0x12

NO_ENTRY = 0xFFFFFFFF


def read_manifest(path):
    """Return the raw AndroidManifest.xml bytes of an APK, or of a bare .xml."""
    if path.lower().endswith(".xml"):
        with open(path, "rb") as f:
            return bytearray(f.read())
    import zipfile
    with zipfile.ZipFile(path) as z:
        return bytearray(z.read("AndroidManifest.xml"))


def read_string_pool(b):
    """Decode the string pool chunk that always sits at offset 8."""
    chunk = 8
    typ, header_size, size = struct.unpack_from("<HHI", b, chunk)
    if typ != RES_STRING_POOL_TYPE:
        raise ValueError("expected a string pool at offset 8, got 0x%04x" % typ)

    count, _style_count, flags, strings_start, _styles_start = struct.unpack_from(
        "<IIIII", b, chunk + 8
    )
    utf8 = bool(flags & 0x100)
    offsets = struct.unpack_from("<%dI" % count, b, chunk + 28)
    base = chunk + strings_start

    def read_at(offset):
        p = base + offset
        if utf8:
            # u16 length (skip), then u8 length
            n = b[p]
            p += 1
            if n & 0x80:
                p += 1
            n = b[p]
            p += 1
            if n & 0x80:
                n = ((n & 0x7F) << 8) | b[p]
                p += 1
            return b[p:p + n].decode("utf-8", "ignore")
        n = struct.unpack_from("<H", b, p)[0]
        p += 2
        if n & 0x8000:
            n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", b, p)[0]
            p += 2
        return b[p:p + n * 2].decode("utf-16-le", "ignore")

    return [read_at(o) for o in offsets]


def iter_elements(b, strings):
    """Yield (element_name, attributes) for every start-element chunk.

    Each attribute is a dict with the absolute offset of its record, so callers
    can patch fields in place:

        a + 0   namespace index    (u32)
        a + 4   name index         (u32)
        a + 8   rawValue index     (u32)  <- what PackageManager actually reads
        a + 12  size(2) res0(1) type(1)
        a + 16  data               (u32)
    """
    pos = 8
    while pos + 8 <= len(b):
        typ, header_size, size = struct.unpack_from("<HHI", b, pos)
        if size <= 0 or pos + size > len(b):
            break
        if typ == RES_XML_START_ELEMENT_TYPE:
            ext = pos + header_size
            _ns, name_index = struct.unpack_from("<II", b, ext)
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", b, ext + 8)
            attrs = []
            for k in range(attr_count):
                a = ext + attr_start + k * attr_size
                ns, nidx, raw, asize, res0, atype, adata = struct.unpack_from(
                    "<IIIHBBI", b, a
                )
                attrs.append({
                    "offset": a,
                    "namespace": strings[ns] if ns < len(strings) else None,
                    "name": strings[nidx] if nidx < len(strings) else "?",
                    "raw": None if raw == NO_ENTRY else strings[raw],
                    "raw_index": raw,
                    "type": atype,
                    "data": adata,
                })
            yield strings[name_index] if name_index < len(strings) else "?", attrs
        pos += size


def describe_value(attr, strings):
    """Human readable rendering of an attribute's typed value."""
    if attr["type"] == TYPE_STRING and attr["data"] < len(strings):
        return strings[attr["data"]]
    if attr["type"] == TYPE_INT_BOOLEAN:
        return "true" if attr["data"] else "false"
    return str(attr["data"])


def set_int(b, attr, value):
    """Write an integer into the typed value slot (a + 16).

    The rawValue index is deliberately left alone: for anything the platform
    reads as an int the typed value is authoritative, and clearing raw would
    make aapt / PackageManager disagree about the attribute being present.
    """
    struct.pack_into("<I", b, attr["offset"] + 16, value & 0xFFFFFFFF)
    attr["data"] = value & 0xFFFFFFFF
    attr["type"] = TYPE_INT_DEC


def set_string(b, attr, strings, text):
    """Point a string-typed attribute at `text`.

    Both the rawValue index and the typed data index must be rewritten.
    PackageManager reports "<attr> has no value" when rawValue is 0xFFFFFFFF,
    so fixing only the typed value silently does nothing.
    """
    try:
        idx = strings.index(text)
    except ValueError:
        raise SystemExit(
            "string %r is not in the pool; this tool never grows the pool, "
            "pick a value that already exists in the manifest" % text
        )
    struct.pack_into("<I", b, attr["offset"] + 8, idx)
    struct.pack_into("<I", b, attr["offset"] + 16, idx)
    attr["raw"] = text
    attr["raw_index"] = idx
    attr["data"] = idx
    attr["type"] = TYPE_STRING
