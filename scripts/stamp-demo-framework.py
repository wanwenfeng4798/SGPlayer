#!/usr/bin/env python3
"""Make a static framework's exact bytes an explicit demo compilation dependency.

Xcode 27's linker dependency file omits the extensionless archive inside this
static framework. A generated C input changes only when the archive changes;
this both forces the required relink and embeds reviewable build provenance.
"""
import hashlib
from pathlib import Path
import sys
archive, destination = map(Path, sys.argv[1:])
with archive.open('rb') as source:
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(block)
text = '/* Generated from the linked SGPlayer static archive. */\n' + 'const char SGDemoLinkedFrameworkSHA256[] __attribute__((used)) = "' + digest.hexdigest() + '";\n'
if not destination.exists() or destination.read_text() != text:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
