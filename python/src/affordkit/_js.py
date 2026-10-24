"""
JavaScript's ways of turning values into text, for text that must read byte for byte as the TypeScript reference writes it:
``String(v)`` and template literals (:func:`js_str`), ``JSON.stringify`` (:func:`js_json`), truthiness (:func:`js_truthy`),
``trim`` and ``length`` (UTF-16 code units). Internal: not part of the API.
"""

from __future__ import annotations

import json
import math
from typing import Any, Iterable


class _Undefined:
    """JavaScript's ``undefined``: a key that isn't there (``None`` is JSON's ``null``)."""

    _instance: "_Undefined | None" = None

    def __new__(cls) -> "_Undefined":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "UNDEFINED"

    def __bool__(self) -> bool:
        return False


UNDEFINED: Any = _Undefined()


def get(d: Any, key: str) -> Any:
    """``d.key``: the value, or UNDEFINED when ``d`` has no such key (or isn't an object)."""
    return d.get(key, UNDEFINED) if isinstance(d, dict) else UNDEFINED


def nullish(v: Any) -> bool:
    """``v == null``: null or undefined."""
    return v is None or v is UNDEFINED


def coalesce(v: Any, fallback: Any) -> Any:
    """``v ?? fallback``."""
    return fallback if nullish(v) else v


def is_num(v: Any) -> bool:
    """``typeof v === 'number'`` (a bool is not one)."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def js_truthy(v: Any) -> bool:
    """JavaScript truthiness: an empty list or object is true, unlike in Python."""
    if nullish(v):
        return False
    if isinstance(v, bool):
        return v
    if is_num(v):
        return v != 0 and not (isinstance(v, float) and math.isnan(v))
    if isinstance(v, str):
        return len(v) > 0
    return True


def strict_eq(a: Any, b: Any) -> bool:
    """``a === b`` for JSON values (objects and arrays are equal only to themselves)."""
    if nullish(a) or nullish(b):
        return a is b
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if is_num(a) and is_num(b):
        return bool(a == b)
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    return a is b


def _is_index(key: str) -> bool:
    # An array index (canonical, below 2**32 - 1): JavaScript puts such keys of an object first, in ascending order.
    return key.isdigit() and key.isascii() and (key == "0" or not key.startswith("0")) and int(key) < 2**32 - 1


def js_entries(d: dict[str, Any]) -> list[tuple[str, Any]]:
    """``Object.entries(d)``, in JavaScript's key order."""
    items = list(d.items())
    index = [kv for kv in items if isinstance(kv[0], str) and _is_index(kv[0])]
    if not index:
        return items
    index.sort(key=lambda kv: int(kv[0]))
    return index + [kv for kv in items if not (isinstance(kv[0], str) and _is_index(kv[0]))]


def js_number(x: float | int) -> str:
    """A number as JavaScript prints it (``Number.prototype.toString``): 312, not 312.0; 1e21; 1e-7; 0.000001."""
    if isinstance(x, int) and abs(x) < 10**21:
        return str(x)
    x = float(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0:
        return "0"
    if x < 0:
        return "-" + js_number(-x)
    r = repr(x)  # the shortest digits that read back as x, as JavaScript picks them
    mant, _, e = r.partition("e")
    exp = int(e) if e else 0
    ip, _, fp = mant.partition(".")
    every = ip + fp
    zeros = len(every) - len(every.lstrip("0"))
    digits = every.lstrip("0").rstrip("0") or "0"
    n = len(ip) + exp - zeros  # x = 0.<digits> * 10**n
    k = len(digits)
    if k <= n <= 21:
        return digits + "0" * (n - k)
    if 0 < n <= 21:
        return digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return "0." + "0" * (-n) + digits
    e1 = n - 1
    return digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + ("+" if e1 >= 0 else "-") + str(abs(e1))


def js_str(v: Any) -> str:
    """``String(v)``, as a template literal ``${v}`` gives it."""
    if v is UNDEFINED:
        return "undefined"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if is_num(v):
        return js_number(v)
    if isinstance(v, str):
        return v
    if isinstance(v, (list, tuple)):
        return js_join(v, ",")
    if isinstance(v, BaseException):
        return f"{type(v).__name__}: {v}" if str(v) else type(v).__name__
    return "[object Object]"


def js_join(items: Iterable[Any], sep: str) -> str:
    """``array.join(sep)``: null and undefined as empty."""
    return sep.join("" if nullish(i) else js_str(i) for i in items)


def js_json(v: Any) -> str:
    """``JSON.stringify(v)``: no spaces, non-ASCII as it is, keys in their order, numbers as JavaScript prints them."""
    if v is UNDEFINED:
        return "undefined"  # (JSON.stringify gives undefined, which a template prints so)
    return _json(v)


def _json(v: Any) -> str:
    if v is None or v is UNDEFINED:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if is_num(v):
        return "null" if isinstance(v, float) and not math.isfinite(v) else js_number(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_json(i) for i in v) + "]"
    if isinstance(v, dict):
        parts = [json.dumps(str(k), ensure_ascii=False) + ":" + _json(x) for k, x in js_entries(v) if x is not UNDEFINED and not callable(x)]
        return "{" + ",".join(parts) + "}"
    return json.dumps(str(v), ensure_ascii=False)


# What String.prototype.trim takes off: WhiteSpace and LineTerminator.
_JS_SPACE = "\t\n\v\f\r                  　﻿"


def js_trim(s: str) -> str:
    """``s.trim()``."""
    return s.strip(_JS_SPACE)


def js_len(s: str) -> int:
    """``s.length``: UTF-16 code units (an emoji is 2)."""
    return len(s.encode("utf-16-le", "surrogatepass")) // 2


def iso_ms(ms: float) -> str:
    """``new Date(ms).toISOString()``: UTC with milliseconds, e.g. 2026-10-21T22:09:32.948Z."""
    t = math.trunc(ms)
    days, rem = divmod(t, 86_400_000)
    # Days since the epoch to a civil date (H. Hinnant's algorithm)
    z = days + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    year = f"{y:04d}" if 0 <= y <= 9999 else ("+" if y > 0 else "-") + f"{abs(y):06d}"
    h, rem = divmod(rem, 3_600_000)
    mi, rem = divmod(rem, 60_000)
    s, msec = divmod(rem, 1000)
    return f"{year}-{m:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}.{msec:03d}Z"
