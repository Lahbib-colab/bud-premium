#!/usr/bin/env python3
"""Compte les accolades d'un fichier Swift avec un vrai analyseur lexical.

Les expressions régulières ne suffisent pas : une interpolation
« \\(...) » peut contenir des guillemets, des parenthèses et des
accolades, et une seule chaîne mal appariée décale tout le reste du
fichier. Les commentaires de bloc Swift s'imbriquent, aussi.

Usage : braces.py fichier.swift [...]
"""
import sys

def scan(src):
    i, n = 0, len(src)
    line = 1
    depth = 0              # profondeur d'accolades dans le code
    first_negative = None
    # pile de contextes : ('code', paren_depth_at_entry) pour une
    # interpolation, ('str', multi) pour une chaîne
    stack = []
    mode = 'code'
    block_comment = 0
    paren = 0
    raw_hashes = 0

    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
            # une chaîne simple ne franchit pas la fin de ligne
            if mode == 'str' and not stack[-1][1]:
                mode, _ = 'code', stack.pop()
            continue

        if mode == 'code':
            if block_comment:
                if src.startswith('/*', i): block_comment += 1; i += 2; continue
                if src.startswith('*/', i): block_comment -= 1; i += 2; continue
                i += 1; continue
            if src.startswith('//', i):
                j = src.find('\n', i)
                i = n if j < 0 else j
                continue
            if src.startswith('/*', i):
                block_comment = 1; i += 2; continue
            if src.startswith('#"', i) or src.startswith('##"', i):
                h = 0
                while src[i + h] == '#': h += 1
                raw_hashes = h
                multi = src.startswith('"""', i + h)
                stack.append(('str', multi))
                mode = 'str'
                i += h + (3 if multi else 1)
                continue
            if src.startswith('"""', i):
                stack.append(('str', True)); mode = 'str'; raw_hashes = 0; i += 3; continue
            if c == '"':
                stack.append(('str', False)); mode = 'str'; raw_hashes = 0; i += 1; continue
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth < 0 and first_negative is None:
                    first_negative = line
            elif c == '(':
                paren += 1
            elif c == ')':
                paren -= 1
                # fin d'une interpolation : on retourne dans la chaîne
                if stack and stack[-1][0] == 'interp' and paren == stack[-1][1]:
                    stack.pop()
                    mode = 'str'
            i += 1
            continue

        # mode == 'str'
        multi = stack[-1][1]
        esc = '\\' + '#' * raw_hashes          # « \ » ou « \# » en chaîne brute
        if src.startswith(esc + '(', i):
            stack.append(('interp', paren))
            mode = 'code'
            paren += 1
            i += len(esc) + 1
            continue
        if src.startswith(esc, i) and not raw_hashes:
            i += 2 if i + 1 < n else 1
            continue
        if multi and src.startswith('"""' + '#' * raw_hashes, i):
            stack.pop(); mode = 'code'; i += 3 + raw_hashes; continue
        if not multi and src.startswith('"' + '#' * raw_hashes, i):
            stack.pop(); mode = 'code'; i += 1 + raw_hashes; continue
        i += 1

    return depth, first_negative, mode, len(stack)

rc = 0
for path in sys.argv[1:]:
    src = open(path, encoding='utf-8').read()
    depth, neg, mode, left = scan(src)
    name = path.split('/')[-1]
    notes = []
    if depth != 0: notes.append(f"solde {depth:+d}")
    if neg: notes.append(f"accolade orpheline ligne {neg}")
    if mode != 'code': notes.append("chaîne non terminée")
    if left: notes.append(f"{left} contexte(s) ouvert(s)")
    if notes:
        rc = 1
        print(f"{name:18} {' · '.join(notes)}")
    else:
        print(f"{name:18} équilibré")
sys.exit(rc)
