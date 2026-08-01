#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Findet Eigenschaften, die in einem QML-Objekt zweimal gesetzt werden.

Weder qmllint noch qmlformat melden das - die QML-Engine dagegen schon, und
zwar erst zur Laufzeit: "Property value set multiple times". Betroffen ist
dann nicht nur der Block, sondern die ganze Datei laedt nicht mehr, und die
App zeigt eine weisse Flaeche. Genau das passierte, als ein einzeiliges
MenuItem eine zusaetzliche visible-Zeile untergeschoben bekam.

Aufruf:  python3 tests/qml_dupprops.py [datei ...]
"""

import re
import sys
import os

# Eigenschaften, die mehrfach vorkommen DUERFEN (Signal-Handler, Listen)
ALLOWED = set()

PROP = re.compile(r'(?:^|\{|;)\s*([a-zA-Z_][\w.]*)\s*:(?!=)')
OBJ = re.compile(r'([A-Z][\w.]*)\s*\{')


def check(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    problems = []
    for i, line in enumerate(lines):
        m = OBJ.search(line)
        if not m:
            continue
        # Blockende ueber Klammertiefe
        depth = 0
        j = i
        props = {}
        while j < len(lines):
            before = depth
            depth += lines[j].count("{") - lines[j].count("}")
            # Nur die direkte Ebene des Objekts betrachten
            # Zeilen, die selbst ein Objekt oeffnen, gehoeren dem KIND -
            # sonst werden die text-Eigenschaften mehrerer MenuItems dem
            # umgebenden ContextMenu zugerechnet (massenhaft Fehlalarm)
            text = lines[j]
            if j == i:
                text = text[m.end() - 1:]
            opens_child = OBJ.search(text) is not None
            # JS-Objektliterale in einem model-Array sind keine Eigenschaften
            if lines[j].lstrip().startswith("{"):
                opens_child = True
            on_own_level = ((j == i) or (before == 1)) and not opens_child
            if on_own_level:
                for pm in PROP.finditer(text):
                    name = pm.group(1)
                    if name in ALLOWED or name.startswith("on"):
                        continue
                    props.setdefault(name, []).append(j + 1)
            # Auch Einzeiler-Objekte beenden den Block - sonst laufen wir in
            # die naechsten Geschwister hinein und halten deren
            # Eigenschaften faelschlich fuer Duplikate
            if depth == 0:
                break
            j += 1
        for name, at in props.items():
            if len(at) > 1:
                problems.append((m.group(1), name, at))
    return problems


def main():
    files = sys.argv[1:]
    if not files:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        files = [os.path.join(root, "qml", "harbour-whatsapp.qml")]
    bad = 0
    for f in files:
        for obj, name, at in check(f):
            bad += 1
            print("  %s: %s setzt '%s' mehrfach (Zeilen %s)"
                  % (os.path.basename(f), obj, name,
                     ", ".join(str(a) for a in at)))
    if bad:
        print("\n%d doppelt gesetzte Eigenschaft(en) - die Datei wuerde zur "
              "Laufzeit nicht laden." % bad)
        return 1
    print("  keine doppelt gesetzten Eigenschaften")
    return 0


if __name__ == "__main__":
    sys.exit(main())
