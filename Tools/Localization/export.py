#!/usr/bin/env python3
"""Validate the shared message table and export deterministic Apple catalogs."""
import argparse
import json
from pathlib import Path
import re
import string

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ['en', 'zh-Hans', 'ja']
IDENTIFIER = re.compile(r'^[a-z][a-z0-9_]*$')

def load_json(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON member: ' + key)
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=unique)

def native_format(template, parameters):
    if not isinstance(template, str) or not template.strip():
        raise ValueError('Translation must be nonempty text')
    found = set()
    result = ''
    for literal, name, specification, conversion in string.Formatter().parse(template):
        result += literal.replace('%', '%%')
        if name is None:
            continue
        names = [p['name'] for p in parameters]
        if name not in names or specification or conversion:
            raise ValueError('Invalid placeholder: ' + name)
        found.add(name)
        index = names.index(name)
        result += '%' + str(index + 1) + '$' + ('lld' if parameters[index]['type'] == 'integer' else '@')
    if found != {p['name'] for p in parameters}:
        raise ValueError('Translation parameters do not match declared parameters')
    return result

def catalogs(data):
    if data.get('sourceLanguage') != 'en' or data.get('languages') != LANGUAGES:
        raise ValueError('Expected en, zh-Hans and ja with English fallback')
    output = {name: {'sourceLanguage': 'en', 'strings': {}, 'version': '1.0'}
              for name in ['Localizable', 'InfoPlist']}
    seen = set()
    for message in data['messages']:
        identifier = message['id']
        if not IDENTIFIER.fullmatch(identifier) or identifier in seen:
            raise ValueError('Invalid or duplicate message ID: ' + identifier)
        seen.add(identifier)
        if not message.get('context', '').strip():
            raise ValueError('Missing translation context: ' + identifier)
        platforms = message.get('platforms', [])
        if not platforms or len(set(platforms)) != len(platforms) or not set(platforms) <= {'apple', 'android'}:
            raise ValueError('Invalid platforms: ' + identifier)
        parameters = message.get('parameters', [])
        names = [p['name'] for p in parameters]
        if len(set(names)) != len(names) or any(not IDENTIFIER.fullmatch(n) for n in names):
            raise ValueError('Invalid parameters: ' + identifier)
        if any(p['type'] not in ['integer', 'text'] for p in parameters):
            raise ValueError('Unsupported parameter type: ' + identifier)
        plural = message.get('plural')
        table = message.get('table', 'Localizable')
        if table not in output or (table == 'InfoPlist' and (parameters or plural)):
            raise ValueError('Invalid resource table or parameterized metadata')
        if plural and (not parameters or parameters[0] != {'name': plural, 'type': 'integer'}):
            raise ValueError('Plural selector must be the first integer parameter: ' + identifier)
        translations = message['translations']
        if set(translations) != set(LANGUAGES):
            raise ValueError('Missing or unexpected language: ' + identifier)
        entry = {'comment': message['context'], 'extractionState': 'manual', 'localizations': {}}
        for language in LANGUAGES:
            value = translations[language]
            if plural:
                expected = {'one', 'other'} if language == 'en' else {'other'}
                if not isinstance(value, dict) or set(value) != expected:
                    raise ValueError('Missing or invalid plural variants: ' + identifier)
                variants = {category: {'stringUnit': {'state': 'translated', 'value': native_format(text, parameters)}}
                            for category, text in value.items()}
                entry['localizations'][language] = {'variations': {'plural': variants}}
            else:
                formatted = native_format(value, parameters)
                if table == 'InfoPlist':
                    formatted = formatted.replace('%%', '%')
                entry['localizations'][language] = {'stringUnit': {'state': 'translated', 'value': formatted}}
        key = message.get('appleKey', identifier)
        if table == 'Localizable' and key != identifier:
            raise ValueError('App strings must use their stable shared ID')
        if key in output[table]['strings']:
            raise ValueError('Duplicate Apple resource key')
        if 'apple' in platforms:
            output[table]['strings'][key] = entry
    return output

def validate_usage(data, sources):
    messages = {m['id']: m for m in data['messages'] if 'apple' in m['platforms'] and m.get('table', 'Localizable') == 'Localizable'}
    # A small lexical check for static calls, including unqualified calls inside L10n.error.
    tokens = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9]*|[^\s]', re.S)
    for source in sources:
        parts = [m.group() for m in tokens.finditer(source) if not m.group().startswith(('//', '/*'))]
        for i, part in enumerate(parts):
            qualified = i >= 2 and parts[i-2:i] == ['L10n', '.']
            helper = 'enum L10n' in source and (i == 0 or parts[i-1] not in ['func', '.'])
            if part != 'text' or not (qualified or helper) or parts[i+1:i+2] != ['(']:
                continue
            key = parts[i+2] if i+2 < len(parts) else ''
            if not re.fullmatch(r'"[a-z0-9_]+"', key):
                raise ValueError('Localization calls require a static message ID')
            key = key[1:-1]
            if key not in messages:
                raise ValueError('Unknown message ID: ' + key)
            depth = 0
            arguments = 0
            for token in parts[i+3:]:
                if token == ')' and depth == 0:
                    break
                if token in ['(', '[', '{']:
                    depth += 1
                elif token in [')', ']', '}']:
                    depth -= 1
                elif token == ',' and depth == 0:
                    arguments += 1
            if arguments != len(messages[key].get('parameters', [])):
                raise ValueError('Argument count does not match message: ' + key)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail if checked-in resources differ from the source table')
    args = parser.parse_args()
    data = load_json((ROOT / 'Localization/messages.json').read_text())
    output = catalogs(data)
    validate_usage(data, [p.read_text() for p in (ROOT / "Apps/Shared").glob("*.swift")])
    for table, catalog in output.items():
        path = ROOT / 'Apps/Shared/Resources' / (table + '.xcstrings')
        expected = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + '\n'
        if args.check:
            if not path.exists() or path.read_text() != expected:
                raise SystemExit('Generated resource differs: ' + str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
    print('Validated', len(data['messages']), 'messages in', ', '.join(LANGUAGES))

if __name__ == '__main__':
    main()
