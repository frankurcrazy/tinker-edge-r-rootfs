#!/usr/bin/env python3
"""Generate a small HDMI EDID (base block + CEA-861 extension) for the
TC358743 HDMI-RX bridge, steering sources to modes a 2-lane CSI-2 link can carry.

    mkedid.py --profile 1080p30 -o edid-1080p30.bin
    mkedid.py --profile 720p60  -o edid-720p60.bin
    mkedid.py --profile 1080p60 -o edid-1080p60.bin   (4-lane boards only)

Load with:  v4l2-ctl -d /dev/v4l-subdevN --set-edid=file=edid-1080p30.bin --fix-edid-checksums
"""
import argparse
import struct
import sys

# CEA-861 short video descriptors (VIC): name -> (vic, pixel clock kHz, H active, H blank, V active, V blank,
#                                                 H sync offset, H sync width, V sync offset, V sync width)
DTD = {
    "1080p60": (16, 148500, 1920, 280, 1080, 45, 88, 44, 4, 5),
    "1080p50": (31, 148500, 1920, 720, 1080, 45, 528, 44, 4, 5),
    "1080p30": (34, 74250, 1920, 280, 1080, 45, 88, 44, 4, 5),
    "1080p25": (33, 74250, 1920, 720, 1080, 45, 528, 44, 4, 5),
    "1080p24": (32, 74250, 1920, 830, 1080, 45, 638, 44, 4, 5),
    "720p60": (4, 74250, 1280, 370, 720, 30, 110, 40, 5, 5),
    "720p50": (19, 74250, 1280, 700, 720, 30, 440, 40, 5, 5),
    "480p60": (2, 27000, 720, 138, 480, 45, 16, 62, 9, 6),
    "576p50": (17, 27000, 720, 144, 576, 49, 12, 64, 5, 5),
}

PROFILES = {
    # profile: (native mode, [SVD list in preference order], max pixel clock MHz, max H kHz)
    "1080p30": ("1080p30", ["1080p30", "1080p25", "1080p24", "720p60", "720p50", "480p60", "576p50"], 80, 50),
    "720p60": ("720p60", ["720p60", "720p50", "480p60", "576p50"], 80, 50),
    "1080p60": ("1080p60", ["1080p60", "1080p50", "1080p30", "1080p25", "1080p24", "720p60", "720p50", "480p60", "576p50"], 160, 70),
}


def dtd_bytes(mode, h_mm=530, v_mm=300):
    vic, pclk, ha, hb, va, vb, hso, hsw, vso, vsw = DTD[mode]
    pc = pclk // 10
    return bytes([
        pc & 0xFF, pc >> 8,
        ha & 0xFF, hb & 0xFF, ((ha >> 8) << 4) | (hb >> 8),
        va & 0xFF, vb & 0xFF, ((va >> 8) << 4) | (vb >> 8),
        hso & 0xFF, hsw & 0xFF, ((vso & 0xF) << 4) | (vsw & 0xF),
        ((hso >> 8) << 6) | ((hsw >> 8) << 4) | ((vso >> 4) << 2) | (vsw >> 4),
        h_mm & 0xFF, v_mm & 0xFF, ((h_mm >> 8) << 4) | (v_mm >> 8),
        0, 0,
        0x1E,  # digital, separate sync, +hsync +vsync
    ])


def checksum(block):
    return bytes([(-sum(block)) & 0xFF])


def manufacturer_id(three_letters):
    a, b, c = (ord(ch) - 64 for ch in three_letters.upper())
    v = (a << 10) | (b << 5) | c
    return struct.pack(">H", v)


def base_block(native, max_pclk_mhz, max_h_khz, name="TinkerHDMIRX"):
    b = bytearray()
    b += b"\x00\xff\xff\xff\xff\xff\xff\x00"     # header
    b += manufacturer_id("TKR")                   # manufacturer
    b += struct.pack("<H", 0x1301)                # product code
    b += struct.pack("<I", 1)                     # serial
    b += bytes([1, 34])                           # week 1, year 2024
    b += bytes([1, 3])                            # EDID 1.3
    b += bytes([0x80])                            # digital input
    b += bytes([53, 30])                          # max image size cm (16:9)
    b += bytes([120])                             # gamma 2.2
    b += bytes([0x1A])                            # features: RGB+YCbCr 4:4:4/4:2:2, preferred timing in DTD1
    b += bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])  # sRGB chromaticity
    b += bytes([0x00, 0x00, 0x00])                # established timings: none
    b += bytes([0x01, 0x01] * 8)                  # standard timings: unused
    b += dtd_bytes(native)                        # DTD 1 (preferred)
    b += dtd_bytes("720p60" if native != "720p60" else "480p60")  # DTD 2
    # monitor name descriptor
    nm = (name[:13] + "\n").ljust(13).encode("ascii")
    b += bytes([0, 0, 0, 0xFC, 0]) + nm
    # range limits: V 23-61 Hz, H 15-max_h kHz, max pixel clock
    b += bytes([0, 0, 0, 0xFD, 0, 23, 61, 15, max_h_khz, max_pclk_mhz // 10, 0, 0x0A]) + b"\x20" * 6
    b += bytes([1])                               # one extension block
    assert len(b) == 127, len(b)
    b += checksum(b)
    return bytes(b)


def cea_block(native, svds, with_audio=True):
    blocks = bytearray()
    # Video data block (tag 2): native flag on the first entry
    vics = [DTD[m][0] for m in svds]
    vd = bytes([0x80 | vics[0]] + vics[1:])
    blocks += bytes([(2 << 5) | len(vd)]) + vd
    if with_audio:
        # Audio data block (tag 1): LPCM, 2 channels, 32/44.1/48 kHz, 16/20/24 bit
        blocks += bytes([(1 << 5) | 3, 0x09, 0x07, 0x07])
        # Speaker allocation (tag 4): FL/FR
        blocks += bytes([(4 << 5) | 3, 0x01, 0x00, 0x00])
    # Vendor specific data block (tag 3): HDMI IEEE OUI 00-0C-03, physical address 1.0.0.0
    blocks += bytes([(3 << 5) | 5, 0x03, 0x0C, 0x00, 0x10, 0x00])
    b = bytearray()
    b += bytes([0x02, 0x03])                      # CEA-861 rev 3
    dtd_offset = 4 + len(blocks)
    flags = 0x80 | (0x40 if with_audio else 0) | 0x30 | 1   # underscan, audio, YCbCr 4:4:4 + 4:2:2, 1 native DTD
    b += bytes([dtd_offset, flags])
    b += blocks
    b += dtd_bytes(native)
    second = "720p60" if native != "720p60" else "480p60"
    if len(b) + 18 <= 127:
        b += dtd_bytes(second)
    b += b"\x00" * (127 - len(b))
    b += checksum(b)
    assert len(b) == 128
    return bytes(b)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", choices=sorted(PROFILES), default="1080p30")
    ap.add_argument("--no-audio", action="store_true", help="do not advertise LPCM audio")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    native, svds, max_pclk, max_h = PROFILES[a.profile]
    edid = base_block(native, max_pclk, max_h) + cea_block(native, svds, not a.no_audio)
    with open(a.output, "wb") as f:
        f.write(edid)
    print(f"wrote {a.output}: {len(edid)} bytes, native {native}, modes {' '.join(svds)}", file=sys.stderr)


if __name__ == "__main__":
    main()
