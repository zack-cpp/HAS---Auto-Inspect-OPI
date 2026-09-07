from __future__ import annotations

from counter_inspect.scanner import KeyboardScanBuffer


def type_text(
    buffer: KeyboardScanBuffer,
    text: str,
    start: float = 1.0,
    gap: float = 0.01,
) -> float:
    timestamp = start
    for character in text:
        buffer.feed(character, timestamp=timestamp)
        timestamp += gap
    return timestamp


def test_fast_employee_url_is_accepted():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "https://host/employee-profile/1234")
    scan = buffer.feed(enter=True, timestamp=timestamp)
    assert scan is not None
    assert scan.barcode == "https://host/employee-profile/1234"


def test_slow_human_typing_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "human input", gap=0.3)
    assert buffer.feed(enter=True, timestamp=timestamp) is None


def test_delayed_enter_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "SKU-123")
    assert buffer.feed(enter=True, timestamp=timestamp + 0.3) is None


def test_fast_spaces_and_punctuation_are_preserved():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "AB 12/34-5")
    scan = buffer.feed(enter=True, timestamp=timestamp)
    assert scan is not None
    assert scan.barcode == "AB 12/34-5"


def test_single_character_sequence_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    buffer.feed("A", timestamp=1.0)
    assert buffer.feed(enter=True, timestamp=1.01) is None


def test_non_printable_keys_are_ignored():
    buffer = KeyboardScanBuffer(0.2)
    buffer.feed("A", timestamp=1.0)
    buffer.feed("\x00", timestamp=1.01)
    buffer.feed("B", timestamp=1.02)
    scan = buffer.feed(enter=True, timestamp=1.03)
    assert scan is not None
    assert scan.barcode == "AB"
