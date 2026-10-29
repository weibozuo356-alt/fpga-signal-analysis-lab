from __future__ import annotations

import argparse
import math
from pathlib import Path


def square_thd(duty: float, highest_harmonic: int) -> float:
    fundamental = math.sin(math.pi * duty)
    harmonic_power = sum(
        (
            math.sin(math.pi * harmonic * duty)
            / (harmonic * fundamental)
        )
        ** 2
        for harmonic in range(2, highest_harmonic + 1)
    )
    return 100.0 * math.sqrt(harmonic_power)


def ideal_square_thd(duty: float) -> float:
    """Return the infinite-harmonic THD of a unipolar pulse train.

    The DC component is excluded, matching the FPGA implementation after
    midpoint removal.  Parseval's theorem gives the total AC power, while
    the first Fourier coefficient gives the fundamental power.
    """
    fundamental_coefficient = math.sin(math.pi * duty) / math.pi
    total_positive_frequency_power = duty * (1.0 - duty) / 2.0
    harmonic_power = (
        total_positive_frequency_power
        - fundamental_coefficient**2
    )
    return 100.0 * math.sqrt(
        harmonic_power / fundamental_coefficient**2
    )


def triangle_thd(highest_harmonic: int) -> float:
    harmonic_power = sum(
        1.0 / harmonic**4
        for harmonic in range(3, highest_harmonic + 1, 2)
    )
    return 100.0 * math.sqrt(harmonic_power)


def relative_error(measured: float, reference: float) -> float:
    return 100.0 * abs(measured - reference) / reference


def boxcar_gain(frequency: float, length: int) -> float:
    angle = math.pi * frequency / 50_000_000.0
    if angle == 0.0:
        return 1.0
    return abs(
        math.sin(length * angle)
        / (length * math.sin(angle))
    )


def filtered_square_thd(
    frequency: float,
    highest_harmonic: int,
) -> float:
    if frequency > 70_000.0:
        average_length = 1
    elif frequency > 35_000.0:
        average_length = 5
    else:
        average_length = 10

    fundamental_gain = boxcar_gain(frequency, average_length)
    harmonic_power = sum(
        (
            boxcar_gain(
                harmonic * frequency,
                average_length,
            )
            / (harmonic * fundamental_gain)
        )
        ** 2
        for harmonic in range(3, highest_harmonic + 1, 2)
    )
    return 100.0 * math.sqrt(harmonic_power)


parser = argparse.ArgumentParser()
parser.add_argument("verilog", type=Path)
args = parser.parse_args()

source_bytes = args.verilog.read_bytes()
try:
    source = source_bytes.decode("utf-8-sig")
except UnicodeDecodeError:
    source = source_bytes.decode("gb18030")

square_reference = ideal_square_thd(0.50)
triangle_reference = 100.0 * math.sqrt(math.pi**4 / 96.0 - 1.0)
square_h49 = square_thd(0.50, 49)
triangle_h49 = triangle_thd(49)

print(f"ideal 50% square THD: {square_reference:.6f}%")
print(
    f"H2..H49 square THD: {square_h49:.6f}% "
    f"(relative error {relative_error(square_h49, square_reference):.3f}%)"
)
print(f"ideal triangle THD: {triangle_reference:.6f}%")
print(
    f"H2..H49 triangle THD: {triangle_h49:.6f}% "
    f"(relative error {relative_error(triangle_h49, triangle_reference):.3f}%)"
)

# The task-5 implementation must select only narrow bands centred on
# integer harmonics.  Summing every bin above the fundamental is THD+N,
# and reproduces the user's >100% result when a 10 mVpp input is noisy.
has_h49 = "AUTO_HIGHEST_HARMONIC = 49" in source
has_harmonic_mask = "thd_auto_harmonic_bin" in source
auto_uses_strict_sum = (
    "thd_auto_harmonic_accumulator" in source
    and "thd_harmonic_power <=\n                            thd_auto_harmonic_accumulator;"
    in source.replace("\r\n", "\n")
)
auto_uses_wideband = (
    "thd_harmonic_power <=\n                            thd_auto_wideband_accumulator;"
    in source.replace("\r\n", "\n")
)

failures: list[str] = []
if relative_error(square_h49, square_reference) >= 3.0:
    failures.append("H49 does not meet the 3% square-wave requirement")
if relative_error(triangle_h49, triangle_reference) >= 3.0:
    failures.append("H49 does not meet the 3% triangle-wave requirement")
if not has_h49:
    failures.append("RTL does not declare H49 as the automatic-mode limit")
if not has_harmonic_mask:
    failures.append("RTL has no integer-harmonic-only bin mask")
if not auto_uses_strict_sum:
    failures.append("automatic mode does not use the strict harmonic sum")
if auto_uses_wideband:
    failures.append("automatic mode still uses the broadband THD+N sum")

# The assignment may select a square-wave duty cycle from 20% to 80%.
# Check the full set of 10%-spaced duty points used in the report, including
# the two worst-looking asymmetric cases at 20% and 80%.
for duty_percent in range(20, 81, 10):
    duty = duty_percent / 100.0
    reference = ideal_square_thd(duty)
    h49_result = square_thd(duty, 49)
    error = relative_error(h49_result, reference)
    print(
        f"duty {duty_percent:2d}% square: ideal {reference:.6f}%, "
        f"H2..H49 {h49_result:.6f}% "
        f"(relative error {error:.3f}%)"
    )
    if error >= 3.0:
        failures.append(
            f"{duty_percent}% duty-cycle square exceeds 3% error"
        )

# Check the points nearest the sample-rate profile boundaries, where
# boxcar averaging causes the largest additional harmonic droop.
for frequency in (10_000.0, 35_000.0, 36_000.0,
                  70_000.0, 71_000.0, 100_000.0):
    filtered_result = filtered_square_thd(frequency, 49)
    filtered_error = relative_error(
        filtered_result,
        square_reference,
    )
    print(
        f"{frequency / 1000:6.1f} kHz filtered square: "
        f"{filtered_result:.6f}% "
        f"(relative error {filtered_error:.3f}%)"
    )
    if filtered_error >= 3.0:
        failures.append(
            f"{frequency / 1000:.1f} kHz filtered square "
            f"exceeds 3% error"
        )

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)

print("PASS: automatic mode sums only H2..H49 harmonic bands")
