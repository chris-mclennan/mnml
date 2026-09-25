"""A small ZON reader for the tour's own data files (masks.zon, asserts.zon).

Enough of the grammar for hand-written data: `.{ … }` as a struct (when
its entries are `.name = value`) or a tuple (otherwise), `.@"quoted"`
field names, strings with Zig's escapes, integers, floats, `true` /
`false` / `null`, enum literals (`.foo` → "foo"), and `//` comments.
It is not the config loader and does not try to be; a file it cannot
read is an error naming the offset, never a silent guess.
"""


class ZonError(ValueError):
    pass


def loads(text):
    p = _Parser(text)
    v = p.value()
    p.ws()
    if p.i != len(p.s):
        raise ZonError(f"trailing text at offset {p.i}")
    return v


def load(path):
    with open(path, encoding="utf-8") as f:
        return loads(f.read())


class _Parser:
    def __init__(self, s):
        self.s = s
        self.i = 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("//", self.i):
                nl = s.find("\n", self.i)
                self.i = len(s) if nl < 0 else nl + 1
            else:
                break

    def peek(self):
        self.ws()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, lit):
        self.ws()
        if not self.s.startswith(lit, self.i):
            raise ZonError(f"expected {lit!r} at offset {self.i}")
        self.i += len(lit)

    def value(self):
        c = self.peek()
        if c == '"':
            return self.string()
        if self.s.startswith(".{", self.i):
            return self.aggregate()
        if c == ".":
            self.i += 1
            return self.ident()
        if c == "-" or c.isdigit():
            return self.number()
        word = self.ident()
        if word == "true":
            return True
        if word == "false":
            return False
        if word == "null":
            return None
        raise ZonError(f"unexpected {word!r} at offset {self.i}")

    def ident(self):
        self.ws()
        if self.s.startswith('@"', self.i):
            self.i += 1
            return self.string()
        j = self.i
        while j < len(self.s) and (self.s[j].isalnum() or self.s[j] == "_"):
            j += 1
        if j == self.i:
            raise ZonError(f"expected a name at offset {self.i}")
        w = self.s[self.i:j]
        self.i = j
        return w

    def number(self):
        self.ws()
        j = self.i
        if self.s[j] == "-":
            j += 1
        while j < len(self.s) and (self.s[j].isalnum() or self.s[j] in "._"):
            j += 1
        tok = self.s[self.i:j].replace("_", "")
        self.i = j
        try:
            return int(tok, 0)
        except ValueError:
            return float(tok)

    def string(self):
        self.expect('"')
        out = []
        s = self.s
        while True:
            if self.i >= len(s):
                raise ZonError("unterminated string")
            c = s[self.i]
            self.i += 1
            if c == '"':
                return "".join(out)
            if c != "\\":
                out.append(c)
                continue
            e = s[self.i]
            self.i += 1
            if e == "n":
                out.append("\n")
            elif e == "t":
                out.append("\t")
            elif e == "r":
                out.append("\r")
            elif e in "\\\"'":
                out.append(e)
            elif e == "x":
                out.append(chr(int(s[self.i:self.i + 2], 16)))
                self.i += 2
            elif e == "u":
                end = s.index("}", self.i)
                out.append(chr(int(s[self.i + 1:end], 16)))
                self.i = end + 1
            else:
                raise ZonError(f"unknown escape \\{e} at offset {self.i}")

    def aggregate(self):
        self.expect(".{")
        items = []
        fields = {}
        is_struct = None
        while True:
            if self.peek() == "}":
                self.i += 1
                break
            save = self.i
            field = None
            if self.peek() == ".":
                self.i += 1
                if self.s.startswith("{", self.i):
                    self.i = save
                else:
                    name = self.ident()
                    if self.peek() == "=":
                        self.i += 1
                        field = name
                    else:
                        self.i = save
            v = self.value()
            if field is not None:
                if is_struct is False:
                    raise ZonError(f"a field in a tuple at offset {save}")
                is_struct = True
                fields[field] = v
            else:
                if is_struct is True:
                    raise ZonError(f"a bare value in a struct at offset {save}")
                is_struct = False
                items.append(v)
            if self.peek() == ",":
                self.i += 1
        return fields if is_struct else (items if is_struct is False else {})
