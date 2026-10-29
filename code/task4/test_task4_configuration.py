from __future__ import annotations

import argparse
from pathlib import Path


FIXED_PROFILES = {
    "000": (1_000, 500, 41),
    "001": (10_000, 50, 41),
    "010": (50_000, 10, 41),
    "011": (1_000_000, 1, 82),
    "100": (1_500_000, 1, 123),
    "101": (2_000_000, 1, 164),
}


parser = argparse.ArgumentParser()
parser.add_argument("verilog", type=Path)
parser.add_argument("hann", type=Path)
args = parser.parse_args()

source_bytes = args.verilog.read_bytes()
try:
    source = source_bytes.decode("utf-8-sig")
except UnicodeDecodeError:
    source = source_bytes.decode("gb18030")

failures: list[str] = []

for code, (frequency, decimation, configured_bin) in FIXED_PROFILES.items():
    effective_rate = 50_000_000 / decimation
    exact_bin = frequency * 4096 / effective_rate
    nearest_bin = round(exact_bin)
    print(
        f"freq_sel={code}: f={frequency} Hz, decimation={decimation}, "
        f"Fs_eff={effective_rate:.0f} Hz, exact bin={exact_bin:.3f}, "
        f"configured bin={configured_bin}"
    )
    if nearest_bin != configured_bin:
        failures.append(
            f"freq_sel={code} should use bin {nearest_bin}, "
            f"not {configured_bin}"
        )
    if f"3'b{code}: decimation_factor = 10'd{decimation};" not in source:
        failures.append(
            f"RTL decimation factor for freq_sel={code} is missing"
        )

hann_values = [
    int(line.strip(), 16)
    for line in args.hann.read_text(encoding="ascii").splitlines()
    if line.strip()
]
print(
    f"Hann coefficients: count={len(hann_values)}, "
    f"min={min(hann_values)}, max={max(hann_values)}, "
    f"first={hann_values[0]}, last={hann_values[-1]}"
)

if len(hann_values) != 4096:
    failures.append("Hann coefficient file does not contain 4096 entries")
if not all(0 <= value <= 32767 for value in hann_values):
    failures.append("Hann coefficient is outside unsigned Q1.15 range")
if "$readmemh(\"hann_4096_q15.mem\", hann_rom);" not in source:
    failures.append("RTL does not load hann_4096_q15.mem")
if "thd_band_half_width =" not in source or "12'd2" not in source:
    failures.append("fixed-mode centre +/-2 bin band is missing")
if "thd_harmonic_power <=" not in source:
    failures.append("fixed-mode harmonic power selection is missing")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)

print("PASS: fixed profiles, Hann table and task-4 band logic are present")
