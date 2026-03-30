"""
macOS virtual keycode mappings.

Maps pynput key names and characters to macOS virtual keycodes
used by CGEventCreateKeyboardEvent.
"""

# macOS virtual keycodes (from Events.h / HIToolbox)
# Character keys - maps lowercase character to keycode
CHAR_TO_KEYCODE = {
    'a': 0x00, 's': 0x01, 'd': 0x02, 'f': 0x03, 'h': 0x04, 'g': 0x05,
    'z': 0x06, 'x': 0x07, 'c': 0x08, 'v': 0x09, 'b': 0x0B, 'q': 0x0C,
    'w': 0x0D, 'e': 0x0E, 'r': 0x0F, 'y': 0x10, 't': 0x11,
    '1': 0x12, '2': 0x13, '3': 0x14, '4': 0x15, '6': 0x16, '5': 0x17,
    '=': 0x18, '9': 0x19, '7': 0x1A, '-': 0x1B, '8': 0x1C, '0': 0x1D,
    ']': 0x1E, 'o': 0x1F, 'u': 0x20, '[': 0x21, 'i': 0x22, 'p': 0x23,
    'l': 0x25, 'j': 0x26, "'": 0x27, 'k': 0x28, ';': 0x29, '\\': 0x2A,
    ',': 0x2B, '/': 0x2C, 'n': 0x2D, 'm': 0x2E, '.': 0x2F,
    '`': 0x32, ' ': 0x31,
}

# Shifted character mappings (character -> base keycode)
# These characters are produced by pressing Shift + another key
SHIFTED_CHAR_TO_KEYCODE = {
    '!': 0x12, '@': 0x13, '#': 0x14, '$': 0x15, '^': 0x16, '%': 0x17,
    '+': 0x18, '(': 0x19, '&': 0x1A, '_': 0x1B, '*': 0x1C, ')': 0x1D,
    '}': 0x1E, '{': 0x21, '|': 0x2A, '<': 0x2B, '>': 0x2F, '?': 0x2C,
    ':': 0x29, '"': 0x27, '~': 0x32,
}

# pynput special key name -> macOS virtual keycode
# pynput Key enum names (e.g. Key.shift -> name='shift')
SPECIAL_KEY_TO_KEYCODE = {
    'enter': 0x24,
    'return': 0x24,
    'tab': 0x30,
    'space': 0x31,
    'backspace': 0x33,
    'delete': 0x33,
    'escape': 0x35,
    'esc': 0x35,

    # Modifiers (left variants)
    'cmd': 0x37,
    'cmd_l': 0x37,
    'cmd_r': 0x36,
    'shift': 0x38,
    'shift_l': 0x38,
    'shift_r': 0x3C,
    'caps_lock': 0x39,
    'alt': 0x3A,
    'alt_l': 0x3A,
    'alt_r': 0x3D,
    'alt_gr': 0x3D,
    'ctrl': 0x3B,
    'ctrl_l': 0x3B,
    'ctrl_r': 0x3E,

    # Arrow keys
    'left': 0x7B,
    'right': 0x7C,
    'down': 0x7D,
    'up': 0x7E,

    # Function keys
    'f1': 0x7A, 'f2': 0x78, 'f3': 0x63, 'f4': 0x76,
    'f5': 0x60, 'f6': 0x61, 'f7': 0x62, 'f8': 0x64,
    'f9': 0x65, 'f10': 0x6D, 'f11': 0x67, 'f12': 0x6F,
    'f13': 0x69, 'f14': 0x6B, 'f15': 0x71, 'f16': 0x6A,
    'f17': 0x40, 'f18': 0x4F, 'f19': 0x50, 'f20': 0x5A,

    # Navigation
    'home': 0x73,
    'end': 0x77,
    'page_up': 0x74,
    'page_down': 0x79,

    # Numpad
    'num_lock': 0x47,

    # Common display-name aliases
    'option': 0x3A,
    'control': 0x3B,
    'command': 0x37,
    'capslock': 0x39,
    'pgup': 0x74,
    'pgdn': 0x79,
}

# CGEvent modifier flag masks
MODIFIER_FLAGS = {
    'shift': 0x00020000,      # kCGEventFlagMaskShift
    'ctrl': 0x00040000,       # kCGEventFlagMaskControl
    'alt': 0x00080000,        # kCGEventFlagMaskAlternate (Option)
    'cmd': 0x00100000,        # kCGEventFlagMaskCommand
    'caps_lock': 0x00010000,  # kCGEventFlagMaskAlphaShift
    'fn': 0x00800000,         # kCGEventFlagMaskSecondaryFn
}


# Reverse lookup tables used by the Quartz keyboard path.
KEYCODE_TO_CHAR = {}
for _ch, _vk in CHAR_TO_KEYCODE.items():
    KEYCODE_TO_CHAR.setdefault(_vk, _ch)

KEYCODE_TO_SHIFTED_CHAR = {}
for _ch, _vk in SHIFTED_CHAR_TO_KEYCODE.items():
    KEYCODE_TO_SHIFTED_CHAR.setdefault(_vk, _ch)

KEYCODE_TO_SPECIAL_NAME = {}
for _name, _vk in SPECIAL_KEY_TO_KEYCODE.items():
    KEYCODE_TO_SPECIAL_NAME.setdefault(_vk, _name)


def get_keycode(key):
    """Get macOS virtual keycode for a pynput key.

    Args:
        key: A pynput Key or KeyCode object.

    Returns:
        Integer keycode, or None if the key can't be mapped.
    """
    # Special key (Key enum member with .name)
    # Handle this first to avoid unnecessary key.char access for keys like Caps Lock.
    try:
        name = key.name
        if isinstance(name, str) and name in SPECIAL_KEY_TO_KEYCODE:
            return SPECIAL_KEY_TO_KEYCODE[name]
    except Exception:
        pass

    # Try pynput's virtual keycode
    try:
        vk = key.vk if hasattr(key, 'vk') else None
        if vk is None and hasattr(key, 'value'):
            vk = key.value.vk
        if isinstance(vk, int):
            return vk
    except Exception:
        pass

    # Character key (KeyCode with .char)
    try:
        char = key.char
        if char is not None:
            c = char.lower()
            if c in CHAR_TO_KEYCODE:
                return CHAR_TO_KEYCODE[c]
            if char in SHIFTED_CHAR_TO_KEYCODE:
                return SHIFTED_CHAR_TO_KEYCODE[char]
    except Exception:
        pass

    return None


def get_keycode_for_name(name):
    """Get keycode from a string key name (used in workflow generation).

    Args:
        name: String like 'a', 'shift', 'enter', etc.

    Returns:
        Integer keycode, or None.
    """
    if len(name) == 1:
        c = name.lower()
        if c in CHAR_TO_KEYCODE:
            return CHAR_TO_KEYCODE[c]
        if name in SHIFTED_CHAR_TO_KEYCODE:
            return SHIFTED_CHAR_TO_KEYCODE[name]
    return SPECIAL_KEY_TO_KEYCODE.get(name.lower())


def key_display_name(key):
    """Get a human-readable display name for a pynput key."""
    try:
        name = key.name
        if isinstance(name, str):
            display_names = {
                'space': 'Space', 'enter': 'Return', 'return': 'Return',
                'tab': 'Tab', 'backspace': 'Delete', 'delete': 'Delete',
                'escape': 'Esc', 'esc': 'Esc',
                'shift': 'Shift', 'shift_l': 'Shift', 'shift_r': 'R-Shift',
                'ctrl': 'Ctrl', 'ctrl_l': 'Ctrl', 'ctrl_r': 'R-Ctrl',
                'alt': 'Option', 'alt_l': 'Option', 'alt_r': 'R-Option',
                'alt_gr': 'R-Option',
                'cmd': 'Cmd', 'cmd_l': 'Cmd', 'cmd_r': 'R-Cmd',
                'caps_lock': 'CapsLock',
                'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right',
                'home': 'Home', 'end': 'End',
                'page_up': 'PgUp', 'page_down': 'PgDn',
            }
            return display_names.get(name, name.upper())
    except Exception:
        pass

    try:
        if key.char is not None:
            return key.char
    except AttributeError:
        pass

    return '?'


def key_name_from_keycode(vk):
    """Return a canonical key name for a virtual keycode."""
    if vk in KEYCODE_TO_SPECIAL_NAME:
        return KEYCODE_TO_SPECIAL_NAME[vk]
    if vk in KEYCODE_TO_CHAR:
        return KEYCODE_TO_CHAR[vk]
    return None


def key_display_name_from_keycode(vk, shift=False):
    """Get a human-readable display name from a macOS virtual keycode."""
    name = key_name_from_keycode(vk)
    if name is None:
        return f'VK{vk}'

    if len(name) == 1:
        if shift and vk in KEYCODE_TO_SHIFTED_CHAR:
            return KEYCODE_TO_SHIFTED_CHAR[vk]
        if shift and name.isalpha():
            return name.upper()
        return name

    display_names = {
        'space': 'Space',
        'enter': 'Return',
        'return': 'Return',
        'tab': 'Tab',
        'backspace': 'Delete',
        'delete': 'Delete',
        'escape': 'Esc',
        'esc': 'Esc',
        'shift': 'Shift',
        'shift_l': 'Shift',
        'shift_r': 'R-Shift',
        'ctrl': 'Ctrl',
        'ctrl_l': 'Ctrl',
        'ctrl_r': 'R-Ctrl',
        'alt': 'Option',
        'alt_l': 'Option',
        'alt_r': 'R-Option',
        'alt_gr': 'R-Option',
        'cmd': 'Cmd',
        'cmd_l': 'Cmd',
        'cmd_r': 'R-Cmd',
        'caps_lock': 'CapsLock',
        'capslock': 'CapsLock',
        'up': 'Up',
        'down': 'Down',
        'left': 'Left',
        'right': 'Right',
        'home': 'Home',
        'end': 'End',
        'page_up': 'PgUp',
        'page_down': 'PgDn',
    }
    return display_names.get(name, name.upper())
